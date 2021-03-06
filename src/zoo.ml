(* This file contains all the common code used by the languages implemented in the PL Zoo.
   In reality the file should be a library consisting of several modules, but just to keep
   the build process a bit simpler, we placed everything in here.
*)

(** Position in source code. For each type in the abstract syntax we define two versions
    [t] and [t']. The former is the latter with a position tag. For example, [expr = expr'
    * position] and [expr'] is the type of expressions (without positions). 
*)
type position =
  | Position of Lexing.position * Lexing.position (** delimited position *)
  | Nowhere (** unknown position *)

(** [nowhere e] is the expression [e] without a source position. It is used when
    an expression is generated and there is not reasonable position that could be
    assigned to it. *)
let nowhere x = (x, Nowhere)

(** Convert a position as presented by [Lexing] to [position]. *)
let position_of_lex lex =
  Position (Lexing.lexeme_start_p lex, Lexing.lexeme_end_p lex)

(** Error reporting. *)

(** Exception [Error (loc, err, msg)] indicates an error of type [err] with
    error message [msg], occurring at position [loc]. *)
exception Error of (position * string * string)

(** [error loc err_type] raises an error of type [err_type]. The [kfprintf] magic allows
    one to write [msg] using a format string. *)
let error ~loc err_type =
  let k _ =
    let msg = Format.flush_str_formatter () in
      raise (Error (loc, err_type, msg))
  in
    Format.kfprintf k Format.str_formatter

(** Common error kinds. *)
let fatal_error ~loc msg = error ~loc "Fatal error" msg
let syntax_error ~loc msg = error ~loc "Syntax error" msg
let typing_error ~loc msg = error ~loc "Typing error" msg
let runtime_error ~loc msg = error ~loc "Runtime error" msg
let warning_error ~loc msg = error ~loc "Warning" msg

(** Pretty-printing of expressions with the Ocaml [Format] library. *)

(** Print an expression, possibly placing parentheses around it. We always
    print things at a given "level" [at_level]. If the level exceeds the
    maximum allowed level [max_level] then the expression should be parenthesized.

    Let us consider an example. When printing nested applications, we should print [App
    (App (e1, e2), e3)] as ["e1 e2 e3"] and [App(e1, App(e2, e3))] as ["e1 (e2 e3)"]. So
    if we assign level 1 to applications, then during printing of [App (e1, e2)] we should
    print [e1] at [max_level] 1 and [e2] at [max_level] 0.
*)
let print ?(max_level=9999) ?(at_level=0) ppf =
  if max_level < at_level then
    begin
      Format.fprintf ppf "(@[" ;
      Format.kfprintf (fun ppf -> Format.fprintf ppf "@])") ppf
    end
  else
    begin
      Format.fprintf ppf "@[" ;
      Format.kfprintf (fun ppf -> Format.fprintf ppf "@]") ppf
    end

(** Print the given source code position. *)
let print_position loc ppf =
  match loc with
  | Nowhere ->
      Format.fprintf ppf "unknown position"
  | Position (begin_pos, end_pos) ->
      let begin_char = begin_pos.Lexing.pos_cnum - begin_pos.Lexing.pos_bol in
      let end_char = end_pos.Lexing.pos_cnum - begin_pos.Lexing.pos_bol in
      let begin_line = begin_pos.Lexing.pos_lnum in
      let filename = begin_pos.Lexing.pos_fname in

      if String.length filename != 0 then
        Format.fprintf ppf "file %S, line %d, charaters %d-%d" filename begin_line begin_char end_char
      else
        Format.fprintf ppf "line %d, characters %d-%d" (begin_line - 1) begin_char end_char

(** Print a sequence of things with the given (optional) separator. *)
let print_sequence ?(sep="") f lst ppf =
  let rec seq = function
    | [] -> print ppf ""
    | [x] -> print ppf "%t" (f x)
    | x :: xs -> print ppf "%t%s@ " (f x) sep ; seq xs
  in
    seq lst

(** Support for printing of errors at various levels of verbosity. *)

let verbosity = ref 2

(** Print a message at a given location [loc] of message type [msg_type] and
    verbosity level [v]. *)
let print_message ?(loc=Nowhere) msg_type v =
  if v <= !verbosity then
    begin
      match loc with
        | Position _ ->
          Format.eprintf "%s at %t:@\n@[" msg_type (print_position loc) ;
          Format.kfprintf (fun ppf -> Format.fprintf ppf "@]@.") Format.err_formatter
        | Nowhere ->
          Format.eprintf "%s:@\n@[" msg_type ;
          Format.kfprintf (fun ppf -> Format.fprintf ppf "@]@.") Format.err_formatter
    end
  else
    Format.ifprintf Format.err_formatter

(** Common message types. *)
let print_error (loc, err_type, msg) = print_message ~loc err_type 1 "%s" msg
let print_warning msg = print_message "Warning" 2 msg
let print_info msg = print_message "Debug" 3 msg

(** Toplevel. *)

module type LANGUAGE =
sig
  type toplevel    (* Parsed toplevel entry. *)
  type environment (* Runtime environment. *)

  val name : string (* The name of the language *)
  val options : (Arg.key * Arg.spec * Arg.doc) list (* Language-specific command-line options *)
  val help_directive : string option (* What to type in toplevel to get help. *)

  val initial_environment : environment (* The initial environment. *)

  val prompt : string (* The prompt to show at toplevel. *)
  val more_prompt : string (* The prompt to show when reading some more. *)
  val read_more : string -> bool (* Given the input so far, should we read more in the interactive shell? *)

  val file_parser : (Lexing.lexbuf -> toplevel list) option (* The file parser *)
  val toplevel_parser : Lexing.lexbuf -> toplevel (* Interactive shell parser *)

  val exec : (environment -> (string * bool) -> environment) -> bool -> environment -> toplevel -> environment (* Execute a toplevel directive. *)
end

module Toplevel(L : LANGUAGE) =
struct

  (** Should the interactive shell be run? *)
  let interactive_shell = ref true

  (** The command-line wrappers that we look for. *)
  let wrapper = ref (Some ["rlwrap"; "ledit"])

  (** The usage message. *)
  let usage = 
    match L.file_parser with
    | Some _ -> "Usage: " ^ L.name ^ " [option] ... [file] ..."
    | None   -> "Usage:" ^ L.name ^ " [option] ..."

  (** A list of files to be loaded and run. *)
  let files = ref []

  (** Add a file to the list of files to be loaded, and record whether it should
      be processed in interactive mode. *)
  let add_file interactive filename = (files := (filename, interactive) :: !files)

  (** Command-line options *)
  let options = Arg.align [
    ("--wrapper",
     Arg.String (fun str -> wrapper := Some [str]),
     "<program> Specify a command-line wrapper to be used (such as rlwrap or ledit)");
    ("--no-wrapper",
     Arg.Unit (fun () -> wrapper := None),
     " Do not use a command-line wrapper");
    ("-v",
     Arg.Unit (fun () ->
       print_endline (L.name ^ " " ^ "(" ^ Sys.os_type ^ ")");
       exit 0),
     " Print language information and exit");
    ("-n",
     Arg.Clear interactive_shell,
     " Do not run the interactive toplevel");
    ("-l",
     Arg.String (fun str -> add_file false str),
     "<file> Load <file> into the initial environment")
  ] @
  L.options

  (** Treat anonymous arguments as files to be run. *)
  let anonymous str =
    add_file true str;
    interactive_shell := false

  (** Parse the contents from a file, using a given [parser]. *)
  let read_file parser fn =
  try
    let fh = open_in fn in
    let lex = Lexing.from_channel fh in
    lex.Lexing.lex_curr_p <- {lex.Lexing.lex_curr_p with Lexing.pos_fname = fn};
    try
      let terms = parser lex in
      close_in fh;
      terms
    with
      (* Close the file in case of any parsing errors. *)
      Error err -> close_in fh ; raise (Error err)
  with
    (* Any errors when opening or closing a file are fatal. *)
    Sys_error msg -> fatal_error ~loc:Nowhere "%s" msg

  (** Parse input from toplevel, using the given [parser]. *)
  let read_toplevel parser () =
    print_string L.prompt ;
    let str = ref (read_line ()) in
      while L.read_more !str do
        print_string L.more_prompt ;
        str := !str ^ (read_line ()) ^ "\n"
      done ;
      parser (Lexing.from_string (!str ^ "\n"))

  (** Parser wrapper that catches syntax-related errors and converts them to errors. *)
  let wrap_syntax_errors parser lex =
    try
      parser lex
    with
      | Failure "lexing: empty token" ->
        syntax_error ~loc:(position_of_lex lex) "unrecognised symbol"
      | _ ->
        syntax_error ~loc:(position_of_lex lex) "general confusion"

  (** Load directives from the given file. *)
  let rec use_file ctx (filename, interactive) =
    match L.file_parser with
    | Some f ->
      let cmds = read_file (wrap_syntax_errors f) filename in
        List.fold_left (L.exec use_file interactive) ctx cmds
    | None ->
      fatal_error ~loc:Nowhere "Cannot load files, only interactive shell is available"

  (** Interactive toplevel *)
  let toplevel ctx =
    let eof = match Sys.os_type with
      | "Unix" | "Cygwin" -> "Ctrl-D"
      | "Win32" -> "Ctrl-Z"
      | _ -> "EOF"
    in
      print_endline (L.name ^ " @ programming languages zoo");
      (match L.help_directive with
        | Some h -> print_endline ("Type " ^ eof ^ " to exit or \"" ^ h ^ "\" for help.") ;
        | None -> print_endline ("Type " ^ eof ^ " to exit.")) ;
      try
        let ctx = ref ctx in
          while true do
            try
              let cmd = read_toplevel (wrap_syntax_errors L.toplevel_parser) () in
                ctx := L.exec use_file true !ctx cmd
            with
              | Error err -> print_error err
              | Sys.Break -> prerr_endline "Interrupted."
          done
      with End_of_file -> ()

  (** Main program *)
  let main () =
    Sys.catch_break true;
    (* Parse the arguments. *)
    Arg.parse options anonymous usage;
    (* Attempt to wrap yourself with a line-editing wrapper. *)
    if !interactive_shell then
      begin match !wrapper with
        | None -> ()
        | Some lst ->
          let n = Array.length Sys.argv + 2 in
          let args = Array.make n "" in
            Array.blit Sys.argv 0 args 1 (n - 2);
            args.(n - 1) <- "--no-wrapper";
            List.iter
              (fun wrapper ->
                try
                  args.(0) <- wrapper;
                  Unix.execvp wrapper args
                with Unix.Unix_error _ -> ())
              lst
      end;
    (* Files were listed in the wrong order, so we reverse them *)
    files := List.rev !files;
    (* Set the maximum depth of pretty-printing, after which it prints ellipsis. *)
    Format.set_max_boxes 42 ;
    Format.set_ellipsis_text "..." ;
    try
      (* Run and load all the specified files. *)
      let ctx = List.fold_left use_file L.initial_environment !files in
        if !interactive_shell then toplevel ctx
    with
        Error err -> print_error err; exit 1
end
