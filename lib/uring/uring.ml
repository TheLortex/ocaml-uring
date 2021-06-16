(*
 * Copyright (C) 2020-2021 Anil Madhavapeddy
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
 *)

module Private = struct
  module Heap = Heap
end

module Region = Region
module Int63 = Optint.Int63

module type FLAGS = sig
  type t = private int
  val of_int : int -> t
  val ( + ) : t -> t -> t
  val mem : t -> t -> bool
end

module Flags = struct
  type t = int

  let empty = 0

  let of_int x = x

  let ( + ) = ( lor )

  let mem a b =
    (a land b) = a
end

module Open_flags = struct
  include Flags

  let rdonly    = Config.o_rdonly
  let wronly    = Config.o_wronly
  let rdwr      = Config.o_rdwr

  let creat     = Config.o_creat
  let excl      = Config.o_excl
  let noctty    = Config.o_noctty
  let trunc     = Config.o_trunc
  let append    = Config.o_append
  let nonblock  = Config.o_nonblock
  let dsync     = Config.o_dsync
  let direct    = Config.o_direct
  let largefile = Config.o_largefile
  let directory = Config.o_directory
  let nofollow  = Config.o_nofollow
  let noatime   = Config.o_noatime
  let cloexec   = Config.o_cloexec
  let sync      = Config.o_sync
  let path      = Config.o_path
  let tmpfile   = Config.o_tmpfile
end

module Resolve = struct
  include Flags

  let no_xdev       = 0x01
  let no_magiclinks = 0x02
  let no_symlinks   = 0x04
  let beneath       = 0x08
  let in_root       = 0x10
  let cached        = 0x20
end

module Poll_mask = struct
  include Flags

  let pollin  = Config.pollin
  let pollout = Config.pollout
  let pollerr = Config.pollerr
  let pollhup = Config.pollhup
end

module Sockaddr = struct
  type t

  external of_unix : Unix.sockaddr -> t = "ocaml_uring_make_sockaddr"
  external get : t -> Unix.sockaddr = "ocaml_uring_extract_sockaddr"

  let dummy_addr = Unix.ADDR_UNIX "-"

  let create () = of_unix dummy_addr
end

module Open_how = struct
  type t

  external make : int -> Unix.file_perm -> int -> string -> t = "ocaml_uring_make_open_how"

  let v ~open_flags ~perm ~resolve path = make open_flags perm resolve path
end

type 'a job = 'a Heap.entry

module Uring = struct
  type t

  external create : int -> t = "ocaml_uring_setup"
  external exit : t -> unit = "ocaml_uring_exit"

  external unregister_bigarray : t -> unit = "ocaml_uring_unregister_ba"
  external register_bigarray : t ->  Iovec.Buffer.t -> unit = "ocaml_uring_register_ba"
  external submit : t -> int = "ocaml_uring_submit"

  type id = Heap.ptr

  type offset = Optint.Int63.t
  external submit_nop : t -> id -> bool = "ocaml_uring_submit_nop" [@@noalloc]
  external submit_poll_add : t -> Unix.file_descr -> id -> Poll_mask.t -> bool = "ocaml_uring_submit_poll_add" [@@noalloc]
  external submit_readv : t -> Unix.file_descr -> id -> Iovec.t -> offset -> bool = "ocaml_uring_submit_readv" [@@noalloc]
  external submit_writev : t -> Unix.file_descr -> id -> Iovec.t -> offset -> bool = "ocaml_uring_submit_writev" [@@noalloc]
  external submit_readv_fixed : t -> Unix.file_descr -> id -> Iovec.Buffer.t -> int -> int -> offset -> bool = "ocaml_uring_submit_readv_fixed_byte" "ocaml_uring_submit_readv_fixed_native" [@@noalloc]
  external submit_writev_fixed : t -> Unix.file_descr -> id -> Iovec.Buffer.t -> int -> int -> offset -> bool = "ocaml_uring_submit_writev_fixed_byte" "ocaml_uring_submit_writev_fixed_native" [@@noalloc]
  external submit_close : t -> Unix.file_descr -> id -> bool = "ocaml_uring_submit_close" [@@noalloc]
  external submit_splice : t -> id -> Unix.file_descr -> Unix.file_descr -> int -> bool = "ocaml_uring_submit_splice" [@@noalloc]
  external submit_connect : t -> id -> Unix.file_descr -> Sockaddr.t -> bool = "ocaml_uring_submit_connect" [@@noalloc]
  external submit_accept : t -> id -> Unix.file_descr -> Sockaddr.t -> bool = "ocaml_uring_submit_accept" [@@noalloc]
  external submit_cancel : t -> id -> id -> bool = "ocaml_uring_submit_cancel" [@@noalloc]
  external submit_openat2 : t -> id -> Unix.file_descr -> Open_how.t -> bool = "ocaml_uring_submit_openat2" [@@noalloc]

  type cqe_option = private
    | Cqe_none
    | Cqe_some of { user_data_id : id; res: int }
  [@@ocaml.warning "-37" (* Avoids "Unused constructor" warning on OCaml <= 4.09. *)]

  external wait_cqe : t -> cqe_option = "ocaml_uring_wait_cqe"
  external wait_cqe_timeout : float -> t -> cqe_option = "ocaml_uring_wait_cqe_timeout"
  external peek_cqe : t -> cqe_option = "ocaml_uring_peek_cqe"

  external error_of_errno : int -> Unix.error = "ocaml_uring_error_of_errno"
end

type 'a t = {
  uring: Uring.t;
  mutable fixed_iobuf: Iovec.Buffer.t;
  data : 'a Heap.t;
  queue_depth: int;
  mutable dirty: bool; (* has outstanding requests that need to be submitted *)
}

let default_iobuf_len = 1024 * 1024 (* 1MB *)

let create ?(fixed_buf_len=default_iobuf_len) ~queue_depth () =
  if queue_depth < 1 then Fmt.invalid_arg "Non-positive queue depth: %d" queue_depth;
  let uring = Uring.create queue_depth in
  (* TODO posix memalign this to page *)
  let fixed_iobuf = Iovec.Buffer.create fixed_buf_len in
  Uring.register_bigarray uring fixed_iobuf;
  Gc.finalise Uring.exit uring;
  let data = Heap.create queue_depth in
  { uring; fixed_iobuf; data; dirty=false; queue_depth }

let realloc t iobuf =
  Uring.unregister_bigarray t.uring;
  t.fixed_iobuf <- iobuf;
  Uring.register_bigarray t.uring iobuf

let exit {uring;_} = Uring.exit uring

let with_id_full : type a. a t -> (Heap.ptr -> bool) -> a -> extra_data:'b -> a job option =
 fun t fn datum ~extra_data ->
  match Heap.alloc t.data datum ~extra_data with
  | exception Heap.No_space -> None
  | entry ->
    let ptr = Heap.ptr entry in
    let has_space = fn ptr in
    if has_space then (
      t.dirty <- true;
      Some entry
    ) else (
      ignore (Heap.free t.data ptr : a);
      None
    )

let with_id t fn a = with_id_full t fn a ~extra_data:()

let noop t user_data =
  with_id t (fun id -> Uring.submit_nop t.uring id) user_data

let at_fdcwd : Unix.file_descr = Obj.magic Config.at_fdcwd

let openat2 t ~access ~flags ~perm ~resolve ?(fd=at_fdcwd) path user_data =
  let open_flags = flags lor match access with
    | `R  -> Open_flags.rdonly
    | `W  -> Open_flags.wronly
    | `RW -> Open_flags.rdwr
  in
  let open_how = Open_how.v ~open_flags ~perm ~resolve path in
  with_id_full t (fun id -> Uring.submit_openat2 t.uring id fd open_how) user_data ~extra_data:open_how

let readv t ~file_offset fd iovec user_data =
  with_id t (fun id -> Uring.submit_readv t.uring fd id iovec file_offset) user_data

let read t ~file_offset fd off len user_data =
  with_id t (fun id -> Uring.submit_readv_fixed t.uring fd id t.fixed_iobuf off len file_offset) user_data

let write t ~file_offset fd off len user_data =
  with_id t (fun id -> Uring.submit_writev_fixed t.uring fd id t.fixed_iobuf off len file_offset) user_data

let writev t ~file_offset fd iovec user_data =
  with_id t (fun id -> Uring.submit_writev t.uring fd id iovec file_offset) user_data

let poll_add t fd poll_mask user_data =
  with_id t (fun id -> Uring.submit_poll_add t.uring fd id poll_mask) user_data

let close t fd user_data =
  with_id t (fun id -> Uring.submit_close t.uring fd id) user_data

let splice t ~src ~dst ~len user_data =
  with_id t (fun id -> Uring.submit_splice t.uring id src dst len) user_data

let connect t fd addr user_data =
  let addr = Sockaddr.of_unix addr in
  with_id_full t (fun id -> Uring.submit_connect t.uring id fd addr) user_data ~extra_data:addr

let accept t fd addr user_data =
  with_id_full t (fun id -> Uring.submit_accept t.uring id fd addr) user_data ~extra_data:addr

let cancel t job user_data =
  with_id t (fun id -> Uring.submit_cancel t.uring id (Heap.ptr job)) user_data

let submit t =
  if t.dirty then begin
    t.dirty <- false;
    Uring.submit t.uring
  end else
    0

type 'a completion_option =
  | None
  | Some of { result: int; data: 'a }

let fn_on_ring fn t =
  match fn t.uring with
  | Uring.Cqe_none -> None
  | Uring.Cqe_some { user_data_id; res } ->
    let data = Heap.free t.data user_data_id in
    Some { result = res; data }

let peek t = fn_on_ring Uring.peek_cqe t

let wait ?timeout t =
  match timeout with
  | None -> fn_on_ring Uring.wait_cqe t
  | Some timeout -> fn_on_ring (Uring.wait_cqe_timeout timeout) t

let queue_depth {queue_depth;_} = queue_depth
let buf {fixed_iobuf;_} = fixed_iobuf

let error_of_errno e =
  Uring.error_of_errno (abs e)
