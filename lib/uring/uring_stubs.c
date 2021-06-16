/*
 * Copyright (C) 2020-2021 Anil Madhavapeddy
 * Copyright (C) 2020-2021 Sadiq Jaffer
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <endian.h>	/* liburing.h needs this for __BYTE_ORDER */
#include <liburing.h>
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>
#include <caml/socketaddr.h>
#include <errno.h>
#include <string.h>
#include <poll.h>

#undef URING_DEBUG
#ifdef URING_DEBUG
#define dprintf(fmt, ...) fprintf(stderr, fmt, ##__VA_ARGS__)
#else
#define dprintf(fmt, ...) ((void)0)
#endif

// TODO: this belongs in Optint
#ifdef ARCH_SIXTYFOUR
#define Int63_val(v) Long_val(v)
#else
#define Int63_val(v) (Int64_val(v)) >> 1
#endif

#define Ring_val(v) *((struct io_uring**)Data_custom_val(v))

static struct custom_operations ring_ops = {
  "uring.ring",
  custom_finalize_default, /* TODO: Finalize should check we've taken down the ring and if not, take it down */
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

value ocaml_uring_setup(value entries) {
  CAMLparam1(entries);
  CAMLlocal1(v_uring);

  struct io_uring* ring = (struct io_uring*)caml_stat_alloc(sizeof(struct io_uring));

  int status = io_uring_queue_init(Long_val(entries), ring, 0);

  if (status == 0) {
      v_uring = caml_alloc_custom_mem(&ring_ops, sizeof(struct io_uring*), sizeof(struct io_uring));
      Ring_val(v_uring) = ring;
      CAMLreturn(v_uring);
  } else
     unix_error(-status, "io_uring_queue_init", Nothing);
}

value ocaml_uring_register_ba(value v_uring, value v_ba) {
  CAMLparam2(v_uring, v_ba);
  struct io_uring *ring = Ring_val(v_uring);
  struct iovec iov[1];
  iov[0].iov_base = Caml_ba_data_val(v_ba);
  iov[0].iov_len = Caml_ba_array_val(v_ba)->dim[0];
  dprintf("uring %p: registering iobuf base %p len %lu\n", ring, iov[0].iov_base, iov[0].iov_len);
  int ret = io_uring_register_buffers(ring, iov, 1);
  if (ret)
    unix_error(-ret, "io_uring_register_buffers", Nothing);
  CAMLreturn(Val_unit);
}

value ocaml_uring_unregister_ba(value v_uring, value v_ba) {
  CAMLparam2(v_uring, v_ba);
  struct io_uring *ring = Ring_val(v_uring);
  dprintf("uring %p: unregistering buffer");
  int ret = io_uring_unregister_buffers(ring);
  if (ret)
    unix_error(-ret, "io_uring_register_buffers", Nothing);
  CAMLreturn(Val_unit);
}

value ocaml_uring_exit(value v_uring) {
  CAMLparam1(v_uring);
  struct io_uring *ring = Ring_val(v_uring);
  dprintf("uring %p: exit\n", ring);
  if (ring) {
    io_uring_queue_exit(ring);
    caml_stat_free(ring);
    Ring_val(v_uring) = NULL;
  }
  CAMLreturn(Val_unit);
}

value
ocaml_uring_submit_nop(value v_uring, value v_id) {
  CAMLparam1(v_uring);
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  io_uring_prep_nop(sqe);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

struct open_how_data {
  struct open_how how;
  char path[];
};

#define Open_how_val(v) (*((struct open_how_data **) Data_custom_val(v)))

static void finalize_open_how(value v) {
  caml_stat_free(Open_how_val(v));
  Open_how_val(v) = NULL;
}

static struct custom_operations open_how_ops = {
  "uring.open_how",
  finalize_open_how,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

value
ocaml_uring_make_open_how(value v_flags, value v_mode, value v_resolve, value v_path) {
  CAMLparam1(v_path);
  CAMLlocal1(v);
  int path_len = caml_string_length(v_path) + 1;
  struct open_how_data *data;
  v = caml_alloc_custom_mem(&open_how_ops, sizeof(struct open_how_data *), sizeof(struct open_how_data) + path_len);
  Open_how_val(v) = NULL;
  data = (struct open_how_data *) caml_stat_alloc(sizeof(struct open_how_data) + path_len);
  data->how.flags = Long_val(v_flags);
  data->how.mode = Long_val(v_mode);
  data->how.resolve = Long_val(v_resolve);
  memcpy(data->path, String_val(v_path), path_len);
  Open_how_val(v) = data;
  CAMLreturn(v);
}

value
ocaml_uring_submit_openat2(value v_uring, value v_id, value v_fd, value v_open_how) {
  CAMLparam2(v_uring, v_open_how);
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  struct open_how_data *data = Open_how_val(v_open_how);
  io_uring_prep_openat2(sqe, Int_val(v_fd), data->path, &data->how);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

value
ocaml_uring_submit_close(value v_uring, value v_fd, value v_id) {
  CAMLparam1(v_uring);
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  dprintf("submit_close: fd:%d\n", Int_val(v_fd));
  io_uring_prep_close(sqe, Int_val(v_fd));
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

value
ocaml_uring_submit_poll_add(value v_uring, value v_fd, value v_id, value v_poll_mask) {
  CAMLparam1(v_uring);
  int poll_mask = Int_val(v_poll_mask);
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  dprintf("submit_poll_add: fd:%d mask:%x\n", Int_val(v_fd), poll_mask);
  io_uring_prep_poll_add(sqe, Int_val(v_fd), poll_mask);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

value
ocaml_uring_submit_readv(value v_uring, value v_fd, value v_id, value v_iov, value v_off) {
  CAMLparam1(v_uring);
  struct io_uring *ring = Ring_val(v_uring);
  struct iovec *iovs = (struct iovec *) (Field(v_iov, 0)  & ~1);
  int len = Wosize_val(Field(v_iov, 1));
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  dprintf("submit_readv: %d ents len[0] %lu off %d\n", len, iovs[0].iov_len, Int63_val(v_off));
  io_uring_prep_readv(sqe, Int_val(v_fd), iovs, len, Int63_val(v_off));
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

value
ocaml_uring_submit_writev(value v_uring, value v_fd, value v_id, value v_iov, value v_off) {
  CAMLparam1(v_uring);
  struct io_uring *ring = Ring_val(v_uring);
  struct iovec *iovs = (struct iovec *) (Field(v_iov, 0) & ~1);
  int len = Wosize_val(Field(v_iov, 1));
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  dprintf("submit_writev: %d ents len[0] %lu off %d\n", len, iovs[0].iov_len, Int63_val(v_off));
  io_uring_prep_writev(sqe, Int_val(v_fd), iovs, len, Int63_val(v_off));
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

value
ocaml_uring_submit_readv_fixed_native(value v_uring, value v_fd, value v_id, value v_ba, value v_off, value v_len, value v_fileoff) {
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  void *buf = Caml_ba_data_val(v_ba) + Long_val(v_off);
  if (!sqe) return Val_false;
  dprintf("submit_readv_fixed: buf %p off %d len %d fileoff %d", buf, Int_val(v_off), Int_val(v_len), Int63_val(v_fileoff));
  io_uring_prep_read_fixed(sqe, Int_val(v_fd), buf, Int_val(v_len), Int63_val(v_fileoff), 0);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  return Val_true;
}

value
ocaml_uring_submit_readv_fixed_byte(value* values, int argc) {
  return ocaml_uring_submit_readv_fixed_native(
			  values[0],
			  values[1],
			  values[2],
			  values[3],
			  values[4],
			  values[5],
			  values[6]);
}

value
ocaml_uring_submit_writev_fixed_native(value v_uring, value v_fd, value v_id, value v_ba, value v_off, value v_len, value v_fileoff) {
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  void *buf = Caml_ba_data_val(v_ba) + Long_val(v_off);
  if (!sqe)
    return Val_false;
  dprintf("submit_writev_fixed: buf %p off %d len %d fileoff %d", buf, Int_val(v_off), Int_val(v_len), Int63_val(v_fileoff));
  io_uring_prep_write_fixed(sqe, Int_val(v_fd), buf, Int_val(v_len), Int63_val(v_fileoff), 0);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  return Val_true;
}

value
ocaml_uring_submit_writev_fixed_byte(value* values, int argc) {
  return ocaml_uring_submit_writev_fixed_native(
			  values[0],
			  values[1],
			  values[2],
			  values[3],
			  values[4],
			  values[5],
			  values[6]);
}

value
ocaml_uring_submit_splice(value v_uring, value v_id, value v_fd_in, value v_fd_out, value v_nbytes) {
  CAMLparam1(v_uring);
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  io_uring_prep_splice(sqe,
		       Int_val(v_fd_in), (int64_t) -1,
		       Int_val(v_fd_out), (int64_t) -1,
		       Int_val(v_nbytes), 0);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

struct sock_addr_data {
  union sock_addr_union sock_addr_addr;
  socklen_param_type sock_addr_len;
};

#define Sock_addr_val(v) (*((struct sock_addr_data **) Data_custom_val(v)))

static void finalize_sock_addr(value v) {
  caml_stat_free(Sock_addr_val(v));
  Sock_addr_val(v) = NULL;
}

static struct custom_operations sockaddr_ops = {
  "uring.sockaddr",
  finalize_sock_addr,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

value
ocaml_uring_make_sockaddr(value v_sockaddr) {
  CAMLparam1(v_sockaddr);
  CAMLlocal1(v);
  struct sock_addr_data *data;
  v = caml_alloc_custom_mem(&sockaddr_ops, sizeof(struct sock_addr_data *), sizeof(struct sock_addr_data));
  Sock_addr_val(v) = NULL;
  data = (struct sock_addr_data *) caml_stat_alloc(sizeof(struct sock_addr_data));
  Sock_addr_val(v) = data;
  // If this raises, the GC will free [v], which will free [data]:
  get_sockaddr(v_sockaddr, &data->sock_addr_addr, &data->sock_addr_len);
  CAMLreturn(v);
}

value
ocaml_uring_extract_sockaddr(value v) {
  CAMLparam1(v);
  CAMLlocal1(v_sockaddr);
  struct sock_addr_data *data = Sock_addr_val(v);
  v_sockaddr = alloc_sockaddr(&data->sock_addr_addr, data->sock_addr_len, -1);
  CAMLreturn(v_sockaddr);
}

// v_sockaddr must not be GC'd while the call is in progress
value
ocaml_uring_submit_connect(value v_uring, value v_id, value v_fd, value v_sockaddr) {
  CAMLparam2(v_uring, v_sockaddr);
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe;
  struct sock_addr_data *addr = Sock_addr_val(v_sockaddr);
  sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  io_uring_prep_connect(sqe, Int_val(v_fd), &(addr->sock_addr_addr.s_gen), addr->sock_addr_len);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

// v_sockaddr must not be GC'd while the call is in progress
value
ocaml_uring_submit_accept(value v_uring, value v_id, value v_fd, value v_sockaddr) {
  CAMLparam2(v_uring, v_sockaddr);
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe;
  struct sock_addr_data *addr = Sock_addr_val(v_sockaddr);
  addr->sock_addr_len = sizeof(union sock_addr_union);
  sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  io_uring_prep_accept(sqe, Int_val(v_fd), &(addr->sock_addr_addr.s_gen), &addr->sock_addr_len, SOCK_CLOEXEC);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

value
ocaml_uring_submit_cancel(value v_uring, value v_id, value v_target) {
  CAMLparam1(v_uring);
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_sqe *sqe;
  sqe = io_uring_get_sqe(ring);
  if (!sqe) CAMLreturn(Val_false);
  io_uring_prep_cancel(sqe, (void *)Long_val(v_target), 0);
  io_uring_sqe_set_data(sqe, (void *)Long_val(v_id));
  CAMLreturn(Val_true);
}

value ocaml_uring_submit(value v_uring)
{
  CAMLparam1(v_uring);
  struct io_uring *ring = Ring_val(v_uring);
  int num = io_uring_submit(ring);
  CAMLreturn(Val_int(num));
}

#define Val_cqe_none Val_int(0)

static value Val_cqe_some(value id, value res) {
  CAMLparam2(id, res);
  CAMLlocal1(some);
  some = caml_alloc(2, 0);
  Store_field(some, 0, id);
  Store_field(some, 1, res);
  CAMLreturn(some);
}

value ocaml_uring_wait_cqe_timeout(value v_timeout, value v_uring)
{
  CAMLparam2(v_uring, v_timeout);
  CAMLlocal1(v_ret);
  double timeout = Double_val(v_timeout);
  struct __kernel_timespec t;
  t.tv_sec = (time_t) timeout;
  t.tv_nsec = (timeout - t.tv_sec) * 1e9;
  long id;
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_cqe *cqe;
  int res;
  dprintf("cqe: waiting, timeout %fs\n", timeout);
  res = io_uring_wait_cqe_timeout(ring, &cqe, &t);
  if (res < 0) {
    if (res == -EAGAIN || res == -EINTR || res == -ETIME) {
      CAMLreturn(Val_cqe_none);
    } else {
      unix_error(-res, "io_uring_wait_cqe_timeout", Nothing);
    }
  } else {
    id = (long)io_uring_cqe_get_data(cqe);
    io_uring_cqe_seen(ring, cqe);
    CAMLreturn(Val_cqe_some(Val_int(id), Val_int(cqe->res)));
  }
}

value ocaml_uring_wait_cqe(value v_uring)
{
  CAMLparam1(v_uring);
  CAMLlocal1(v_ret);
  long id;
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_cqe *cqe;
  int res;
  dprintf("cqe: waiting\n");
  res = io_uring_wait_cqe(ring, &cqe);
  if (res < 0) {
    if (res == -EAGAIN || res == -EINTR) {
      CAMLreturn(Val_cqe_none);
    } else {
      unix_error(-res, "io_uring_wait_cqe", Nothing);
    }
  } else {
    id = (long)io_uring_cqe_get_data(cqe);
    io_uring_cqe_seen(ring, cqe);
    CAMLreturn(Val_cqe_some(Val_int(id), Val_int(cqe->res)));
  }
}

value ocaml_uring_peek_cqe(value v_uring)
{
  CAMLparam1(v_uring);
  CAMLlocal1(v_ret);
  long id;
  struct io_uring *ring = Ring_val(v_uring);
  struct io_uring_cqe *cqe;
  int res;
  dprintf("cqe: peeking\n");
  res = io_uring_peek_cqe(ring, &cqe);
  if (res < 0) {
    if (res == -EAGAIN || res == -EINTR) {
      CAMLreturn(Val_cqe_none);
    } else {
      unix_error(-res, "io_uring_peek_cqe", Nothing);
    }
  } else {
    id = (long)io_uring_cqe_get_data(cqe);
    io_uring_cqe_seen(ring, cqe);
    CAMLreturn(Val_cqe_some(Val_int(id), Val_int(cqe->res)));
  }
}

// Allocates
value ocaml_uring_error_of_errno(value v_errno) {
  return unix_error_of_code(Int_val(v_errno));
}
