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

type t = {
  connection : Rpc.Connection.t;
  log : Oci_Log.line Pipe.Writer.t;
}

(** Enter inside the namespace *)
let () =
  Caml.Unix.chroot ".";
  Caml.Unix.chdir "/"

let start ~implementations =
  begin
    let implementations =
      (Rpc.Rpc.implement Oci_Artefact_Api.rpc_stop_runner
         (fun _ () -> shutdown 0; return ()))::
       implementations in
    let implementations =
      Rpc.Implementations.create_exn
        ~on_unknown_rpc:`Raise
        ~implementations in
    let named_pipe = Sys.argv.(1) in
    Reader.open_file (named_pipe^".in")
    >>> fun reader ->
    Writer.open_file (named_pipe^".out")
    >>> fun writer ->
    Rpc.Connection.create
      ~implementations
      ~connection_state:(fun c -> c)
      reader writer
    >>> fun conn ->
    let conn = Result.ok_exn conn in
    Shutdown.at_shutdown (fun () ->
        Rpc.Connection.close conn
        >>= fun () ->
        Reader.close reader;
        >>= fun () ->
        Writer.close writer
      )
  end;
  Scheduler.go ()

let implement data f =
  Rpc.Pipe_rpc.implement
    (Oci_Data.both data)
    (fun connection q ~aborted:_ ->
       let reader,writer = Pipe.create () in
       let res = Ivar.create () in
       begin
         Pipe.init
           (fun log ->
              Monitor.try_with_or_error
                (fun () -> f {connection;log} q)
              >>= fun r -> Ivar.fill res r; Deferred.unit)
         |> fun log -> Pipe.transfer log writer
           ~f:(fun l -> Oci_Data.Line l)
         >>> fun () ->
         Ivar.read res
         >>> fun res ->
         Pipe.write writer (Oci_Data.Result res)
         >>> fun () ->
         Pipe.downstream_flushed writer
         >>> fun _ ->
         Pipe.close writer
       end;
       Deferred.Or_error.return reader
    )


let write_log kind t fmt =
  Printf.ksprintf (fun s ->
      s
      |> String.split_lines
      |> List.iter
        ~f:(fun line -> Pipe.write_without_pushback t.log {kind;line})
    ) fmt

let std_log t fmt = write_log Oci_Log.Standard t fmt
let err_log t fmt = write_log Oci_Log.Error t fmt
let cmd_log t fmt = write_log Oci_Log.Command t fmt
let cha_log t fmt = write_log Oci_Log.Chapter t fmt

type artefact = Oci_Common.Artefact.t with sexp, bin_io

let create_artefact t ~dir =
  cmd_log t "Create artefact %s" dir;
  Rpc.Rpc.dispatch_exn Oci_Artefact_Api.rpc_create
    t.connection dir
let link_artefact t ?(user=Oci_Common.Root) src ~dir =
  cmd_log t "Link artefact to %s" dir;
  Rpc.Rpc.dispatch_exn Oci_Artefact_Api.rpc_link_to
    t.connection (user,src,dir)
let copy_artefact t ?(user=Oci_Common.Root) src ~dir =
  cmd_log t "Copy artefact to %s" dir;
  Rpc.Rpc.dispatch_exn Oci_Artefact_Api.rpc_copy_to
    t.connection (user,src,dir)

let get_internet t =
  cmd_log t "Get internet";
  Rpc.Rpc.dispatch_exn Oci_Artefact_Api.rpc_get_internet
    t.connection ()

let git_clone t ?(user=Oci_Common.Root) ~url ~dst =
  cmd_log t "Git clone %s in %s" url dst;
  Rpc.Rpc.dispatch_exn Oci_Artefact_Api.rpc_git_clone
    t.connection (url,dst,user)

let dispatch t d q =
  cmd_log t "Dispatch %s" (Oci_Data.name d);
  Rpc.Rpc.dispatch (Oci_Data.rpc d) t.connection q
  >>= fun r ->
  return (Or_error.join r)

let dispatch_exn t d q =
  cmd_log t "Dispatch %s" (Oci_Data.name d);
  Rpc.Rpc.dispatch_exn (Oci_Data.rpc d) t.connection q
  >>= fun r ->
  return (Or_error.ok_exn r)

let process_log t p =
  let send_to_log t kind reader =
    let reader = Reader.lines reader in
    Pipe.transfer ~f:(fun line -> {kind;line}) reader t.log in
  don't_wait_for (send_to_log t Oci_Log.Standard (Process.stdout p));
  don't_wait_for (send_to_log t Oci_Log.Error (Process.stderr p))

let process_create t ?working_dir ?env ~prog ~args () =
  cmd_log t "Run: %s %s" prog (String.concat ~sep:" " args);
  let open Deferred.Or_error in
  Process.create ?working_dir ?env ~prog ~args ()
  >>= fun p ->
  process_log t p;
  return p

exception CommandFailed

let run t ?working_dir ?env ~prog ~args () =
  process_create t ?working_dir ?env ~prog ~args ()
  >>= fun p ->
  let p = Or_error.ok_exn p in
  Process.wait p
  >>= fun r ->
  match r with
  | Core_kernel.Std.Result.Ok () -> return ()
  | Core_kernel.Std.Result.Error _ as error ->
    err_log t "Command %s failed: %s"
      prog
      (Unix.Exit_or_signal.to_string_hum error);
    raise CommandFailed
