(**************************************************************************)
(*                                                                        *)
(*  This file is part of OCI.                                             *)
(*                                                                        *)
(*  Copyright (C) 2015-2016                                               *)
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
open Oci_Common

open Log.Global

let (>>!) or_error_deferred f =
  or_error_deferred >>= fun r -> f (ok_exn r)

exception RunnerFailed of Unix.Exit_or_signal.error [@@deriving sexp]

let get_etc_sub_config ~user ~file =
  file
  |> Reader.open_file
  >>= fun reader ->
  reader
  |> Reader.lines
  |> Pipe.filter_map
    ~f:(fun s ->
        match String.split s ~on:':' with
        | [u;start;len] when String.equal u user ->
          Some (Int.of_string start,Int.of_string len)
        | _ -> None
      )
  |> Pipe.read
  >>= function
  | `Eof ->
    eprintf "This user doesn't have subuid or subgid configured (cf %s) \n%!"
      file;
    Oci_Artefact_Api.oci_shutdown 1
  | `Ok start_len -> return start_len

let stderr_pipe = Writer.pipe (Lazy.force Writer.stderr)

let send_to_stderr name reader =
  let reader = Reader.lines reader in
  Pipe.transfer ~f:(fun x -> name^x^"\n") reader stderr_pipe

let send_process_to_stderr name process =
  don't_wait_for (send_to_stderr name (Process.stdout process));
  don't_wait_for (send_to_stderr name (Process.stderr process))

let () =
  Oci_Artefact_Api.oci_at_shutdown (fun () ->
      Deferred.ignore (Pipe.upstream_flushed stderr_pipe)
    )

type process = {
  wrapper : Process.t;
  wrapped : Pid.t;
  (** We don't want to use [Process.wait wrapper] more than once,
      otherwise one receive an error not existing
  *)
  wrapper_wait : Unix.Exit_or_signal.t Deferred.t;
}


type conf = {
  current_user: User.t;
  first_user_mapped: User.t;
  mutable conn_to_artefact: Rpc.Connection.t option;
  mutable wait_to_artefact: unit Deferred.t option;
  wrappers_dir : Oci_Filename.t;
  running_processes: process Int.Table.t;
  cgroup: string option;
  cpuset_available: bool;
  binaries: Oci_Filename.t list;
  oci_wrapper: Oci_Filename.t;
}

let find_binary l binary_name =
  Deferred.List.find_map l ~f:(fun dir ->
      let abs = Oci_Filename.concat dir binary_name in
      Sys.file_exists_exn abs
      >>= fun b ->
      return (if b then Some abs else None)
    )
  >>= function
  | None -> error "Can't find binary %s in binaries directories" binary_name;
    Shutdown.exit 1
  | Some p -> return p

let cleanup_running_processes conf () =
  begin match conf.wait_to_artefact with
  | None ->
    info "No master to stop";
    return ()
  | Some wait ->
    let timeout = Time.Span.create ~sec:10 () in
    info "Master have %s to stop nicely" (Time.Span.to_string_hum timeout);
    Deferred.ignore
      (Clock.with_timeout timeout
         begin (match conf.conn_to_artefact with
             | None -> return ()
             | Some conn ->
               Rpc.Rpc.dispatch Oci_Artefact_Api.rpc_stop_runner conn ()
               >>= fun _ ->
               wait)
         end)
  end
  >>= fun () ->
  Int.Table.iteri
    ~f:(fun ~key:_ ~data:process ->
        if not (Deferred.is_determined process.wrapper_wait) then begin
          debug "Send kill signal to %s" (Pid.to_string process.wrapped);
          Signal.send_i Signal.kill (`Pid process.wrapped)
        end)
    conf.running_processes;
  conf.running_processes
  |> Int.Table.fold
    ~f:(fun ~key:_ ~data:process acc ->
        (Deferred.ignore process.wrapper_wait)::acc)
    ~init:[]
  |> Deferred.all_unit

let create_cgroup ~conf cgroup_name =
  match conf.cgroup, cgroup_name with
  | None, _ | _, None -> Deferred.return None
  | Some cgroup_root, Some cgroup_name ->
    let cgroup = cgroup_root ^ "/" ^ cgroup_name in
    debug "Create cgroup %s" cgroup;
    Async_shell.test "cgm" ["create";"all";cgroup]
    >>= function
    | true -> Deferred.return (Some cgroup)
    | false ->
      error
        "Can't create cgroup %s. You should create and give ownership of \n\
         the cgroup:\n\
         - sudo cgm create all %s\n\
         - sudo cgm chown  all %s %i %i\n\
        " cgroup cgroup_root cgroup_root (Unix.getuid ()) (Unix.getgid ());
      exit 1

let exec_in_namespace =
  let wrapper_id = ref (-1) in
  fun conf parameters ->
    (* create_cgroup *)
    create_cgroup ~conf parameters.Oci_Wrapper_Api.cgroup
    >>= fun cgroup ->
    let parameters = {parameters with cgroup;
                                      initial_cpuset =
                                        if conf.cpuset_available
                                        then parameters.initial_cpuset
                                        else None
                     } in
    (* create communication channel *)
    incr wrapper_id;
    let named_pipe = Oci_Filename.make_absolute conf.wrappers_dir
        (Printf.sprintf "wrappers%i" !wrapper_id)  in
    let named_pipe_in = named_pipe^".in" in
    let named_pipe_out = named_pipe^".out" in
    Unix.mkfifo named_pipe_in
    >>= fun () ->
    Unix.mkfifo named_pipe_out
    >>= fun () ->
    Process.create ~prog:(conf.oci_wrapper) ~args:[named_pipe] ()
    >>! fun wrapper ->
    debug "Oci_Wrapper started";
    send_process_to_stderr (sprintf "[R%i]" parameters.runner_id)  wrapper;
    Writer.close (Process.stdin wrapper)
    >>= fun () ->
    let read_wrapped_pid =
      Writer.open_file named_pipe_in
      >>= fun writer ->
      Unix.unlink named_pipe_in
      >>= fun () ->
      Writer.write_bin_prot writer
        Oci_Wrapper_Api.bin_writer_parameters
        parameters;
      Writer.close writer
      >>= fun () ->
      debug "Oci_Wrapper configuration sent";
      Reader.open_file named_pipe_out
      >>= fun reader ->
      Unix.unlink named_pipe_out
      >>= fun () ->
      Reader.read_bin_prot reader Pid.bin_reader_t
      >>= fun res ->
      Reader.close reader
      >>= fun () ->
      return res
    in
    let wrapper_wait = Process.wait wrapper in
    Deferred.choose
      [Deferred.choice wrapper_wait
         (fun res -> Error res);
       Deferred.choice read_wrapped_pid
         (fun wrapped -> Ok wrapped)
      ]
    >>= function
    | Error res ->
      let res = Unix.Exit_or_signal.to_string_hum res in
      error "Oci_wrapper stopped before sending wrapped pid %s:\n%s\n"
        res
        (Sexp.to_string_hum (Oci_Wrapper_Api.sexp_of_parameters parameters));
      return (Or_error.error_string res)
    | Ok `Eof ->
      error "The pid of the wrapped program can't be read";
      return (Or_error.error_string "Wrapper error: can't get pid")
    | Ok (`Ok wrapped) ->
      debug "Oci_Wrapper: runner %i has pid %s"
        parameters.runner_id (Pid.to_string wrapped);
      let process_info = {
        wrapper; wrapped; wrapper_wait;
      } in
      Int.Table.add_exn conf.running_processes ~key:parameters.runner_id
        ~data:process_info;
      process_info.wrapper_wait
      >>= fun res ->
      debug "Wrapped program %s for runner %i ended" (Pid.to_string wrapped)
        parameters.runner_id;
      Int.Table.remove conf.running_processes parameters.runner_id;
      match res, Oci_Artefact_Api.oci_shutting_down () with
      | Ok (),_ -> return (Or_error.return ())
      | Error (`Signal s), true when s = Signal.kill ->
        debug "Runner %i received kill signal for shutdown"
          parameters.runner_id;
        return (Or_error.error_string "Shutdown")
      | Error _ as res, _ ->
        let res = Unix.Exit_or_signal.to_string_hum res in
        error "The following program stopped with this error %s:\n%s\n"
          res
          (Sexp.to_string_hum (Oci_Wrapper_Api.sexp_of_parameters parameters));
        return (Or_error.error_string res)

let kill_runner conf i =
  match Int.Table.find conf.running_processes i with
  | None -> return ()
  | Some process_info ->
    Deferred.choose [
      Deferred.choice
        (Clock.after (Time.Span.create ~ms:500 ()))
        (fun () -> `Kill);
      Deferred.choice
        process_info.wrapper_wait
        (fun _ -> `Done)
    ]
    >>= function
    | `Done -> return ()
    | `Kill ->
      debug "Sending kill to runner %i pid %s"
        i (Pid.to_string process_info.wrapped);
      match Signal.send Signal.kill (`Pid process_info.wrapped) with
      | `No_such_process -> return ()
      | `Ok ->
        Deferred.ignore (process_info.wrapper_wait)


let compute_conf ~oci_data ~cgroup ~binaries ~cpuset_available =
  find_binary binaries "Oci_Wrapper.native"
  >>= fun oci_wrapper ->
  User_and_group.for_this_process_exn ()
  >>= fun ug ->
  let current_user = {User.uid=Unix.getuid ();gid=Unix.getgid ()} in
  get_etc_sub_config ~user:(User_and_group.user ug) ~file:"/etc/subuid"
  >>= fun (ustart, ulen) ->
  get_etc_sub_config ~user:(User_and_group.user ug) ~file:"/etc/subgid"
  >>= fun (gstart, glen) ->
  if ulen < 1001 || glen < 1001 then begin
    eprintf
      "This user doesn't have enough subuid or \
       subgid configured (1001 needed)\n%!";
    Oci_Artefact_Api.oci_shutdown 1
  end
  else
    let first_user_mapped = {User.uid=ustart;gid=gstart} in
    let conf = {current_user;first_user_mapped;conn_to_artefact=None;
                wait_to_artefact=None;
                wrappers_dir =
                  Oci_Filename.make_absolute oci_data "wrappers";
                running_processes = Int.Table.create ();
                cgroup;
                cpuset_available;
                binaries;
                oci_wrapper;
               } in
    Async_shell.run "mkdir" ["-p";"--";oci_data]
    >>= fun () ->
    Unix.chmod ~perm:0o777 oci_data
    >>= fun () ->
    Async_shell.run "rm" ["-rf";"--";conf.wrappers_dir]
    >>= fun () ->
    Async_shell.run "mkdir" ["-p";"--";conf.wrappers_dir]
    >>= fun () ->
    return conf

let start_master ~conf ~master ~oci_data ~binaries
    ~proc ~verbosity ~cleanup_rootfs
    ~identity_file =
  find_binary binaries master
  >>= fun master ->
  let named_pipe = Oci_Filename.concat oci_data "oci_master" in
  begin match proc with
    | [] -> error "We must have at least two group of processor";
      Oci_Artefact_Api.oci_shutdown 1
    | [_] -> error "We have only one group of processor,\
                     you should not use cpuinfo";
      Oci_Artefact_Api.oci_shutdown 1
    | master_proc::procs -> return (master_proc,procs)
  end
  >>= fun (master_proc,proc) ->
  let parameters = {
    Oci_Wrapper_Api.rootfs = "/";
    idmaps =
      Oci_Wrapper_Api.idmaps
        ~first_user_mapped:conf.first_user_mapped
        ~in_user:master_user
        [Superroot,1;Root,1000;User,1];
    command = master;
    argv = [named_pipe];
    env = ["PATH","/usr/local/bin:/usr/bin:/bin"];
    runuid = 0;
    rungid = 0;
    bind_system_mount = false;
    prepare_network = false;
    workdir = None;
    cgroup = Some "master";
    initial_cpuset = Some master_proc;
    runner_id = -1;
  } in
  let implementations = Rpc.Implementations.create_exn
      ~on_unknown_rpc:`Raise
      ~implementations:[
        Rpc.Rpc.implement Oci_Artefact_Api.get_configuration
          (fun () () -> begin
               match identity_file with
               | Some file ->
                 Reader.file_contents file
                 >>= fun s -> return (Some s)
               | None -> return None
             end
             >>= fun identity_file ->
             return {Oci_Artefact_Api.binaries;
                     oci_data;
                     first_user_mapped = conf.first_user_mapped;
                     debug_level = verbosity = `Debug;
                     cleanup_rootfs;
                     identity_file;
                     proc;
                     master_proc;
                    });
        Rpc.Rpc.implement Oci_Artefact_Api.exec_in_namespace
          (fun () -> exec_in_namespace conf);
        Rpc.Rpc.implement Oci_Artefact_Api.rpc_kill_runner
          (fun () -> kill_runner conf);
        Rpc.Rpc.implement Oci_Artefact_Api.set_cpuset
          (fun () (a:Oci_Artefact_Api.set_cpuset) ->
             if conf.cpuset_available && conf.cgroup <> None then
               Async_shell.run "cgm"
                 ["setvalue";"cpuset";
                  a.cgroup; "cpuset.cpus";
                  (String.concat ~sep:"," (List.map ~f:Int.to_string a.cpuset))]
             else Deferred.unit
          );
      ]
  in
  info "Start master";
  Oci_Artefact_Api.start_in_namespace
    ~exec_in_namespace:(exec_in_namespace conf) ~parameters
    ~named_pipe
    ~implementations
    ~initial_state:()
    ()
  >>= fun (error,conn) ->
  conf.wait_to_artefact <- Some (error >>= fun _ -> return ());
  Deferred.upon conn (fun conn -> conf.conn_to_artefact <- Some conn);
  error
  >>= function
  | Ok () when Oci_Artefact_Api.oci_shutting_down () ->
    info "master stopped for shutdown";
    Deferred.unit
  | Ok () ->
    info "master stopped unexpectedly but normally";
    Oci_Artefact_Api.oci_shutdown 1
  | Error s ->
    info "master stopped unexpectedly with error: %s"
      (Error.to_string_hum s);
    Oci_Artefact_Api.oci_shutdown 1

let run
    master binaries oci_data identity_file
    verbosity cleanup_rootfs cgroup (proc,cpuset_available) =
  Log.Global.set_level verbosity;
  assert (not (Signal.is_managed_by_async Signal.term));
  (* Handle nicely terminating signals *)
  Signal.handle Signal.terminating ~f:(fun s ->
      if Oci_Artefact_Api.oci_shutting_down ()
      then
        info "Shutting down already started: monitor received %s"
          (Signal.to_string s)
      else begin
        info "Shutting down: monitor received %s" (Signal.to_string s);
        don't_wait_for (Oci_Artefact_Api.oci_shutdown 0)
      end
    );
  compute_conf ~oci_data ~cgroup ~binaries ~cpuset_available
  >>= fun conf ->
  Oci_Artefact_Api.oci_at_shutdown (cleanup_running_processes conf);
  start_master ~conf ~binaries ~oci_data ~master
    ~proc ~verbosity ~cleanup_rootfs
    ~identity_file

(* cpuinfo *)
type cpu_data = {
  processor  : Int.t;
  physical_id: Int.t;
  core_id    : Int.t;
}

type cpuinfo = {
  nb_cpus: Int.t;
  cpu_datas: cpu_data Int.Table.t;
  layout: cpu_data list list;
}

let read_cpuinfo () =
  let cpu_datas = Int.Table.create () in
  let rec read_processor cin =
    let processor = ref None in
    let core_id = ref None in
    let physical_id = ref None in
    let set_int r i =
      try r := Some (Int.of_string i)
      with _ -> error "Error during /proc/cpuinfo parsing"
    in
    let rec read_next () =
      match
        List.map ~f:(String.strip ?drop:None)
          (String.split ~on:':' (Caml.Pervasives.input_line cin)) with
      | [""] ->
        begin
          match !processor, !core_id, !physical_id with
          | Some processor, Some core_id, Some physical_id -> begin
            let cpu_data = {processor;physical_id;core_id} in
            match Int.Table.add_or_error cpu_datas
                    ~key:cpu_data.processor
                    ~data:cpu_data with
            | Ok () -> read_processor cin
            | Error _ ->
              error "Error during /proc/cpuinfo parsing: duplicate processor";
              Caml.Pervasives.exit 1
            end
          | _ ->
            error "Error during /proc/cpuinfo parsing: \
                   cpuinfo parsing error, not all fields founds";
            Caml.Pervasives.exit 1
        end
      | ["processor";i] -> set_int processor i; read_next ()
      | ["core id";i] -> set_int core_id i; read_next ()
      | ["physical id";i] -> set_int physical_id i; read_next ()
      | _ -> read_next ()
    in
    read_next ()
  in
  let cin = Caml.Pervasives.open_in "/proc/cpuinfo" in
  try read_processor cin
  with
  | End_of_file ->
    Caml.Pervasives.close_in cin;
    {
      nb_cpus = Int.Table.length cpu_datas;
      cpu_datas = cpu_datas;
      layout =
        let h = Hashtbl.Poly.create () in
        Hashtbl.iteri cpu_datas
          ~f:(fun ~key:_ ~data ->
              Hashtbl.add_multi h
                ~key:(data.physical_id,data.core_id)
                ~data
            );
        Hashtbl.data h
    }
  | exn -> Caml.Pervasives.close_in cin; raise exn

let partition_cpus cpuinfo cpus =
  List.filter_map
      cpuinfo.layout
      ~f:(fun l ->
          match List.filter_map l ~f:(fun s ->
              if List.mem cpus s.processor then Some s.processor else None) with
          | [] -> None
          | l -> Some l)


let list_interval i1 i2 =
  let l = ref [] in
  for i=i1 to i2 do
    l := i::!l
  done;
  !l


open Cmdliner

let help_secs = [
 `S "BUGS"; `P "Check bug reports at the oci repository.";]

let current_work_dir = Caml.Sys.getcwd ()
let abs_file kind =
  let map_to_absolute f =
    if Oci_Filename.is_relative f
    then Oci_Filename.make_absolute current_work_dir f
    else f
  in
  let parse s =
    let ret b error =
      if b
      then `Ok (map_to_absolute s)
      else `Error error
    in
    match kind with
    | `Regular -> ret (Caml.Sys.file_exists s && not (Caml.Sys.is_directory s))
                    "must be a regular file"
    | `Dir -> ret (Caml.Sys.file_exists s && Caml.Sys.is_directory s)
                "must be a directory"
    | `Exec -> ret (Caml.Sys.file_exists s && not (Caml.Sys.is_directory s))
                 "must be an executable"
  in
  parse, Format.pp_print_string

let int_list =
  let parse s =
    let l = String.split ~on:',' s in
    let interval si =
      match String.split ~on:'-' si with
      | [i1;i2] -> list_interval (Int.of_string i1) (Int.of_string i2)
      | _ -> raise Exit
    in
    try
      let l = List.map ~f:interval l in
      `Ok (List.concat l)
    with _ -> `Error
                (Printf.sprintf "Error during parsing of list of int: %s" s)
  in
  let print fmt l =
    let l = List.map ~f:Int.to_string l in
    Format.pp_print_string fmt (String.concat ~sep:"," l)
  in
  parse, print

let log_level =
  let parse s =
    try `Ok (Log.Level.of_string s)
    with _ -> `Error "Log level should be [Debug|Info|Error]"
  in
  parse, (fun fmt s -> Format.pp_print_string fmt (Log.Level.to_string s))

let cmd =
  let master =
    let def = "oci-default-master" in
    Arg.(value & opt string def & info ["master"]
           ~docv:"EXEC"
           ~doc:"Specify the master to use. Must be in the binaries.")
  in
  let binaries =
    Arg.(non_empty & opt_all (abs_file `Dir)
           [Oci_Filename.make_absolute Oci_Version.lib_install_dir "bin"]
         & info ["binaries"]
           ~docv:"DIR"
           ~doc:"Specify where the runners are.")
  in
  let oci_data =
    let def = Oci_Version.default_oci_data in
    Arg.(value & opt (abs_file `Dir) def & info ["oci-data"]
           ~docv:"DIR"
           ~doc:"Specify where the OCI should store its files.")
  in
  let identity_file =
    Arg.(value & opt (some (abs_file `Regular)) None & info ["identity-file"]
           ~docv:"FILE"
           ~doc:"Specify an identity file to use for ssh connection.")
  in
  let verbosity =
    Arg.(value & opt log_level `Info & info ["verbose"]
           ~docv:"[Debug|Error|Info]"
           ~doc:"Specify the verbosity level.")
  in
  let keep_runner_rootfs =
    Arg.(value & vflag true [false,
                             info ["keep-runner-rootfs"]
                               ~doc:"For debugging keep the rootfs used after \
                                     the end of the runner."])
  in
  let cgroup =
    Arg.(value & opt (some string) None &
         info ["cgroup"]
           ~docv:"NAME"
           ~doc:"Indicate in which cgroup OCI has the right to create cgroups")
  in
  let proc =
    Arg.(value & opt (some int) None & info ["proc"]
           ~docv:"N"
           ~doc:"Maximum number of worker to run simultaneously. Subsumed by \
                 --cpus. Default is 4 except")
  in
  let cpus =
    Arg.(value & opt (some int_list) None &
         info ["cpus"]
           ~docv:"NAME"
           ~doc:"Indicate which cpus should be used. Format list of cpus \
                 number or interval \"1,3,2,7,8-12,15\"")
  in
  let cpuinfo =
    Arg.(value & flag &
         info ["cpuinfo"]
           ~docv:"NAME"
           ~doc:"Indicate to read /proc/cpuinfo for getting the cpu layout. \
                 The cpu layout is used for keeping two cpus running on the \
                 same core (hyper-threading) to be used by two different \
                 runners. It is also used for computing the default of --proc \
                 as the number of cpus on the computer")
  in
  let parse_proc proc cpus cpuinfo =
    let cpuinfo = if not cpuinfo then None
      else Some (read_cpuinfo ())
    in
    let cpus = match cpus with
      | None ->
        let default = match cpuinfo with
          | None -> 4
          | Some cpuinfo -> cpuinfo.nb_cpus
        in
        let nb = (Option.value ~default proc) in
        list_interval 0 (nb-1)
      | Some l -> l
    in
    match cpuinfo with
    | Some cpuinfo -> partition_cpus cpuinfo cpus, true
    | None ->
      (* no sibling information: cpus don't have siblings *)
      List.map ~f:(fun x -> [x]) cpus, false
  in
  let doc = "Start an Oci  monitor and the given master" in
  let man = [
    `S "DESCRIPTION";
    `P "Add the specified packages in the given rootfs"] @ help_secs
  in
  Term.(const run $ master $ binaries $ oci_data $
        identity_file $ verbosity $ keep_runner_rootfs $ cgroup $
        (Term.(const parse_proc $ proc $ cpus $ cpuinfo))),
  Term.info "Oci_Monitor" ~doc ~man ~version:Oci_Version.version


let () =
  don't_wait_for begin
    match Term.eval cmd with
    | `Error _ -> exit 1
    | `Ok r -> begin r >>= fun () ->
        Oci_Artefact_Api.oci_shutdown 0
      end
    | `Help | `Version -> exit 0
  end

let () = Scheduler.report_long_cycle_times ()
let () = never_returns (Scheduler.go ())
