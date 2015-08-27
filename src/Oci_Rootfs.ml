(**************************************************************************)
(*                                                                        *)
(*  This file is part of Frama-C.                                         *)
(*                                                                        *)
(*  Copyright (C) 2013                                                    *)
(*    CEA (Commissariat à l'énergie atomique et aux énergies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

open Core.Std
open Async.Std

open Log.Global

open Oci_Rootfs_Api

(** The rootfs master is special because it create the environnement,
    so it need to runs in masters task that should be done in a runner *)

let rootfs_next_id = ref (-1)
let db_rootfs : rootfs Rootfs_Id.Table.t ref = ref (Rootfs_Id.Table.create ())

let testdir () =
  Oci_Master.permanent_directory Oci_Rootfs_Api.create_rootfs
  >>= fun dir ->
  return (Oci_Filename.make_absolute dir "testdir")


let () =
  let module M = struct
    type t = {rootfs_next_id: Int.t;
              db_rootfs: (Rootfs_Id.t * rootfs) list;
             } with bin_io
  end in
  Oci_Master.simple_register_saver
    Oci_Rootfs_Api.create_rootfs
    M.bin_t
    ~basename:"rootfs_next_id"
    ~saver:(fun () ->
        info "rootfs: %i" (Rootfs_Id.Table.length !db_rootfs);
        let db_rootfs = Rootfs_Id.Table.to_alist !db_rootfs in
        info "rootfs_alist: %i" (List.length db_rootfs);
        return {M.rootfs_next_id = !rootfs_next_id;
                db_rootfs})
    ~loader:(fun r ->
        rootfs_next_id := r.M.rootfs_next_id;
        db_rootfs := Rootfs_Id.Table.of_alist_exn r.M.db_rootfs;
        info "rootfs: %i" (Rootfs_Id.Table.length !db_rootfs);
        return ())
    ~init:(fun () ->
        testdir ()
        >>= fun testdir ->
        Async_shell.run "rm" ["-rf";"--";testdir]
        >>= fun () ->
        Unix.mkdir ~p:() testdir)

let create_new_rootfs rootfs_query =
  testdir ()
  >>= fun testdir ->
  incr rootfs_next_id;
  let id = Rootfs_Id.of_int_exn (!rootfs_next_id) in
  let testdir = Oci_Filename.make_absolute testdir (Rootfs_Id.to_string id) in
  Monitor.protect
    ~finally:(fun () -> Async_shell.run "rm" ["-rf";"--";testdir])
    (fun () ->
       Unix.mkdir testdir
       >>= fun () -> begin
       match rootfs_query.meta_tar with
       | None -> return None
       | Some meta_tar ->
         let metadir = Oci_Filename.make_absolute testdir "meta" in
         Unix.mkdir metadir
         >>= fun () ->
         Async_shell.run "tar" ["Jxf";meta_tar;"-C";metadir]
         >>= fun () ->
         let exclude = Oci_Filename.make_absolute metadir "excludes-user" in
         Sys.file_exists_exn exclude
         >>= fun exi ->
         if exi
         then return (Some exclude)
         else return None
       end
       >>= fun exclude ->
       let rootfsdir = Oci_Filename.make_absolute testdir "rootfs" in
       Unix.mkdir rootfsdir
       >>= fun () ->
       Async_shell.run "tar" (["xf";rootfs_query.rootfs_tar; "--xz";
                               "-C";rootfsdir;
                               "--preserve-order";
                               "--no-same-owner";
                              ]@
                              (match exclude with
                               | None -> []
                               | Some exclude -> ["--exclude-from";exclude]
                              ))
       >>= fun () ->
       Oci_Artefact.create rootfsdir
       >>= fun a ->
       let rootfs = {
         id;
         info = rootfs_query.rootfs_info;
         rootfs = a
       } in
       Rootfs_Id.Table.add_exn !db_rootfs ~key:id ~data:rootfs;
       return rootfs
    )
  >>= fun s ->
  return s

let find_rootfs key =
  return (Rootfs_Id.Table.find_exn !db_rootfs key)

let register_rootfs () =
  Oci_Master.register
    Oci_Rootfs_Api.create_rootfs
    (fun s -> Deferred.Or_error.try_with (fun () -> create_new_rootfs s));
  Oci_Master.register
    Oci_Rootfs_Api.find_rootfs
    (fun s -> Deferred.Or_error.try_with (fun () -> find_rootfs s))