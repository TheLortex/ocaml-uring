module Int63 = Optint.Int63

let assert_       ~__POS__ = Alcotest.(check ~pos:__POS__ bool) "" true
let assert_some x ~__POS__ = Alcotest.(check ~pos:__POS__ bool) "" true (x <> None)
let check_raises  ~__POS__ = Alcotest.check_raises ~pos:__POS__ ""
let check_int     ~__POS__ ~expected = Alcotest.(check ~pos:__POS__ int) "" expected
let check_string  ~__POS__ ~expected = Alcotest.(check ~pos:__POS__ string) "" expected
let check_bool    ~__POS__ ~expected = Alcotest.(check ~pos:__POS__ bool) "" expected

module Heap = struct
  module Heap = struct
    include Uring.Private.Heap
    let alloc = alloc ~extra_data:()
  end

  let random_hashtbl_elt tbl =
    let rec inner n acc (seq : _ Seq.t) =
      match seq () with
      | Nil -> acc
      | Cons (x, xf) ->
        let acc = if Random.int n = 0 then x else acc in
        inner (succ n) acc xf
    in
    match Hashtbl.to_seq tbl () with
    | Nil -> invalid_arg "random_hashtbl_elt"
    | Cons (x, xf) -> inner 1 x xf

  let check_raises_no_space ~__POS__:pos f =
    Alcotest.check_raises ~pos "" Heap.No_space (fun () -> ignore (f ()))

  let test_normal_usage () =
    let max_size = 10 in
    let t = Heap.create max_size in
    let reference : (Heap.ptr, int) Hashtbl.t = Hashtbl.create max_size in
    let currently_allocated = ref 0 in
    for _ = 1 to 100_000 do
      let attempt_alloc = !currently_allocated = 0 || Random.bool () in
      match attempt_alloc with
      | true ->
        if !currently_allocated = max_size then
          check_raises_no_space ~__POS__ (fun () -> Heap.alloc t 0)
        else
          let data = Random.int 5000 in
          let ptr = Heap.ptr (Heap.alloc t data) in
          assert_ ~__POS__ (not (Hashtbl.mem reference ptr));
          Hashtbl.add reference ptr data;
          incr currently_allocated
      | false ->
        let (k, v) = random_hashtbl_elt reference in
        let v' = Heap.free t k in
        Hashtbl.remove reference k;
        check_int ~__POS__ ~expected:v v';
        decr currently_allocated
    done

  let test_double_free () =
    let () =
      (* Double free in an empty heap *)
      let t = Heap.create 1 in
      let p = Heap.ptr @@ Heap.alloc t 1 in
      check_int ~__POS__ ~expected:1 (Heap.free t p);
      check_raises ~__POS__ (Invalid_argument "Heap.free: pointer already freed")
        (fun () -> ignore (Heap.free t p))
    in
    let () =
      (* Double free in a non-empty heap *)
      let t = Heap.create 2 in
      let p = Heap.ptr @@ Heap.alloc t 1 in
      let _ = Heap.ptr @@ Heap.alloc t 2 in
      check_int ~__POS__ ~expected:1 (Heap.free t p);
      check_raises ~__POS__ (Invalid_argument "Heap.free: pointer already freed")
        (fun () -> ignore (Heap.free t p))
    in
    ()

  let test_out_of_space () =
    let () =
      let t = Heap.create 0 in
      (* 1 > 0 *)
      check_raises_no_space ~__POS__ (fun () -> Heap.ptr @@ Heap.alloc t ())
    in
    let () =
      let t = Heap.create 2 in
      let _ : Heap.ptr = Heap.ptr @@ Heap.alloc t () in
      let _ : Heap.ptr = Heap.ptr @@ Heap.alloc t () in
      (* 3 > 2 *)
      check_raises_no_space ~__POS__ (fun () -> Heap.ptr @@ Heap.alloc t ())
    in
    let () =
      let t = Heap.create 3 in
      let p1 = Heap.ptr @@ Heap.alloc t 1 in
      let _ : Heap.ptr = Heap.ptr @@ Heap.alloc t 2 in
      check_int ~__POS__ ~expected:1 (Heap.free t p1);
      let _ : Heap.ptr = Heap.ptr @@ Heap.alloc t 3 in
      let _ : Heap.ptr = Heap.ptr @@ Heap.alloc t 4 in
      (* 2 - 1 + 2 > 3 *)
      check_raises_no_space ~__POS__ (fun () -> Heap.ptr @@ Heap.alloc t 5);
    in
    ()
end

module Test_data = struct
  let path = "output_file.txt"

  let setup () =
    let oc = open_out path in
    output_string oc "A test file";
    close_out oc

  let with_fd f =
    let fd = Unix.openfile path [ O_RDONLY ] 0 in
    let a = f fd in
    Unix.close fd;
    a
end

let rec consume t =
  match Uring.wait ~timeout:1. t with
  | Some { data; result } -> (data, result)
  | None -> consume t

let test_invalid_queue_depth () =
  check_raises ~__POS__ (Invalid_argument "Non-positive queue depth: 0")
    (fun () -> ignore (Uring.create ~queue_depth:0 ()))

let with_uring ~queue_depth fn =
  let t = Uring.create ~queue_depth () in
  fn t;
  Uring.exit t  (* Only free if there wasn't an error *)

let test_noop () =
  let queue_depth = 5 in
  with_uring ~queue_depth @@ fun t ->

  for i = 1 to queue_depth do
    assert_some ~__POS__ (Uring.noop t i);
  done;

  check_int ~__POS__ (Uring.submit t) ~expected:queue_depth;

  for i = 1 to queue_depth do
    let tkn, res = consume t in
    check_int ~__POS__ ~expected:i tkn;
    check_int ~__POS__ ~expected:0 res
  done

let test_open () =
  with_uring ~queue_depth:1 @@ fun t ->
  assert_some ~__POS__ (Uring.openat2 t
                          ~access:`R
                          ~flags:Uring.Open_flags.empty
                          ~perm:0
                          ~resolve:Uring.Resolve.empty
                          "/dev/null"
                          `Open);
  check_int   ~__POS__ (Uring.submit t) ~expected:1;
  let token, fd = consume t in
  assert_   ~__POS__ (token = `Open);
  assert (fd >= 0);
  let fd : Unix.file_descr = Obj.magic fd in
  let got = Unix.read fd (Bytes.create 5) 0 5 in
  check_int   ~__POS__ got ~expected:0;
  Unix.close fd

let test_create () =
  with_uring ~queue_depth:1 @@ fun t ->
  let old_mask = Unix.umask 0o077 in
  Fun.protect ~finally:(fun () -> ignore (Unix.umask old_mask)) @@ fun () ->
  assert_some ~__POS__ (Uring.openat2 t
                          ~access:`RW
                          ~flags:Uring.Open_flags.creat
                          ~perm:0o644
                          ~resolve:Uring.Resolve.empty
                          "test-openat"
                          `Create);
  check_int ~__POS__ (Uring.submit t) ~expected:1;
  let token, fd = consume t in
  assert_ ~__POS__ (token = `Create);
  assert (fd >= 0);
  let fd : Unix.file_descr = Obj.magic fd in
  check_int ~__POS__ ~expected:4 (Unix.write fd (Bytes.of_string "Test") 0 4);
  check_int ~__POS__ ~expected:0o600 (Unix.fstat fd).st_perm;
  Unix.close fd

let test_resolve () =
  with_uring ~queue_depth:1 @@ fun t ->
  let get ~resolve path =
    assert_some ~__POS__ (Uring.openat2 t
                            ~access:`R
                            ~flags:Uring.Open_flags.path
                            ~perm:0
                            ~resolve
                            path
                            `Get_path);
    check_int ~__POS__ (Uring.submit t) ~expected:1;
    let token, fd = consume t in
    assert_ ~__POS__ (token = `Get_path);
    if fd >= 0 then (
      let fd : Unix.file_descr = Obj.magic fd in
      Unix.close fd;
      true
    ) else if fd = -18 then (
      false
    ) else (
      Fmt.failwith "unexpected error: %d" fd
    )
  in
  check_bool ~__POS__ ~expected:true @@ get ~resolve:Uring.Resolve.empty ".";
  check_bool ~__POS__ ~expected:true @@ get ~resolve:Uring.Resolve.beneath ".";
  check_bool ~__POS__ ~expected:true @@ get ~resolve:Uring.Resolve.empty "..";
  check_bool ~__POS__ ~expected:false @@ get ~resolve:Uring.Resolve.beneath ".."

let test_read () =
  with_uring ~queue_depth:1 @@ fun t ->
  Test_data.with_fd @@ fun fd ->

  let off = 3 in
  let len = 5 in
  let file_offset = Int63.of_int 2 in
  assert_some ~__POS__ (Uring.read t ~file_offset fd off len `Read);
  check_int   ~__POS__ (Uring.submit t) ~expected:1;

  let token, read = consume t in
  assert_   ~__POS__ (token = `Read);
  check_int ~__POS__ read ~expected:len;

  let fbuf = Uring.buf t in
  check_string ~__POS__  ~expected:"test "
    (Bigstringaf.substring fbuf ~off ~len)

let test_readv () =
  with_uring ~queue_depth:1 @@ fun t ->
  Test_data.with_fd @@ fun fd ->

  let b1_len = 3 and b2_len = 7 in
  let b1 = Iovec.Buffer.create b1_len and b2 = Iovec.Buffer.create b2_len in
  let iov = Iovec.alloc [| b1; b2 |] in

  assert_some ~__POS__ (Uring.readv t fd iov `Readv ~file_offset:Int63.zero);
  check_int   ~__POS__ (Uring.submit t) ~expected:1;

  let token, read = consume t in
  assert_      ~__POS__ (token = `Readv);
  check_int    ~__POS__ ~expected:(b1_len + b2_len) read;
  check_string ~__POS__ ~expected:"A t"     (Bigstringaf.to_string b1);
  check_string ~__POS__ ~expected:"est fil" (Bigstringaf.to_string b2);
  ()

(* Ask to read from a pipe (with no data available), then cancel it. *)
let test_cancel () =
  with_uring ~queue_depth:5 @@ fun t ->
  (* while true do *)
  let r, w = Unix.pipe () in
  let read = Uring.read t ~file_offset:Int63.zero r 0 1 `Read |> Option.get in
  assert_some ~__POS__ (Uring.cancel t read `Cancel);
  check_int   ~__POS__ (Uring.submit t) ~expected:2;
  let t1, r1 = consume t in
  let t2, r2 = consume t in
  let r_read, r_cancel =
    match t1, t2 with
    | `Read, `Cancel -> r1, r2
    | `Cancel, `Read -> r2, r1
    | _ -> assert false
  in
  if r_read = -4 then (
    (* Occasionally, the read is actually busy just as we try to cancel.
       In that case it gets interrupted and the cancel returns EALREADY. *)
    check_int ~__POS__ ~expected:(-4)   r_read;   (* EINTR *)
    check_int ~__POS__ ~expected:(-114) r_cancel; (* EALREADY *)
  ) else (
    (* This is the common case. The read is blocked and can just be removed. *)
    check_int ~__POS__ ~expected:(-125) r_read;   (* ECANCELED *)
    check_int ~__POS__ ~expected:0      r_cancel; (* Success *)
  );
  Unix.close r;
  Unix.close w
  (* done *)

(* By the time we cancel, the request has already succeeded (we just didn't process the reply yet). *)
let test_cancel_late () =
  with_uring ~queue_depth:5 @@ fun t ->
  let r = Unix.openfile "/dev/zero" Unix.[O_RDONLY] 0 in
  let read = Uring.read t ~file_offset:Int63.zero r 0 1 `Read |> Option.get in
  check_int   ~__POS__ (Uring.submit t) ~expected:1;
  assert_some ~__POS__ (Uring.cancel t read `Cancel);
  check_int   ~__POS__ (Uring.submit t) ~expected:1;
  let t1, r1 = consume t in
  let t2, r2 = consume t in
  let r_read, r_cancel =
    match t1, t2 with
    | `Read, `Cancel -> r1, r2
    | `Cancel, `Read -> r2, r1
    | _ -> assert false
  in
  check_int ~__POS__ ~expected:1    r_read;   (* Success *)
  check_int ~__POS__ ~expected:(-2) r_cancel; (* ENOENT *)
  Unix.close r

(* By the time we cancel, we already knew the operation was over. *)
let test_cancel_invalid () =
  with_uring ~queue_depth:5 @@ fun t ->
  let r = Unix.openfile "/dev/zero" Unix.[O_RDONLY] 0 in
  let read = Uring.read t ~file_offset:Int63.zero r 0 1 `Read |> Option.get in
  let token, r_read = consume t in
  assert_   ~__POS__ (token = `Read);
  check_int ~__POS__ ~expected:1    r_read;   (* Success *)
  Unix.close r;
  (* Try to cancel after we may have reused the index: *)
  check_raises ~__POS__
    (Invalid_argument "Entry has already been freed!")
    (fun () -> ignore (Uring.cancel t read `Cancel))

let () =
  Test_data.setup ();
  Random.self_init ();
  let tc name f = Alcotest.test_case name `Quick f in
  Alcotest.run __FILE__ [
    "heap", [
      tc "normal_usage" Heap.test_normal_usage;
      tc "double_free" Heap.test_double_free;
      tc "out_of_space" Heap.test_out_of_space;
    ];
    "uring", [
      tc "invalid_queue_depth" test_invalid_queue_depth;
      tc "noop" test_noop;
      tc "open" test_open;
      tc "create" test_create;
      tc "resolve" test_resolve;
      tc "read" test_read;
      tc "readv" test_readv;
      tc "cancel" test_cancel;
      tc "cancel_late" test_cancel_late;
      tc "cancel_invalid" test_cancel_invalid;
    ];
  ]

