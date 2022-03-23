open Lwt.Syntax

type response_handler = H2.Client_connection.response_handler

type do_request =
  ?trailers_handler:(H2.Headers.t -> unit) ->
  H2.Request.t ->
  response_handler:response_handler ->
  [ `write ] H2.Body.t

let make_request ~scheme ~service ~rpc ~headers =
  let request =
    H2.Request.create ~scheme `POST ("/" ^ service ^ "/" ^ rpc) ~headers
  in
  request

let default_headers =
  H2.Headers.of_list
    [ ("te", "trailers"); ("content-type", "application/grpc+proto") ]

let status_of_headers headers =
  match H2.Headers.get headers "grpc-status" with
  | Some s -> (
      let code =
        match int_of_string_opt s with
        | None -> None
        | Some i -> Grpc.Status.code_of_int i
      in
      match code with
      | None -> None
      | Some code ->
          let message = H2.Headers.get headers "grpc-message" in
          let status = Grpc.Status.v ?message code in
          Some status)
  | None -> None

let extract_status status_notify headers =
  Option.iter (Lwt.wakeup_later status_notify) (status_of_headers headers)

let call ~service ~rpc ?(scheme = "https") ~handler ~do_request
    ?(headers = default_headers) () =
  let request = make_request ~service ~rpc ~scheme ~headers in
  let read_body, read_body_notify = Lwt.wait () in
  let handler_res, handler_res_notify = Lwt.wait () in
  let out, out_notify = Lwt.wait () in
  let status, status_notify = Lwt.wait () in
  let response_handler (response : H2.Response.t) body =
    Lwt.wakeup_later read_body_notify body;
    Lwt.async (fun () ->
        if response.status <> `OK then (
          Lwt.wakeup_later out_notify
            (Error (Grpc.Status.v Grpc.Status.Unknown));
          Lwt.return_unit)
        else
          let () = extract_status status_notify response.headers in
          let+ handler_res in
          Lwt.wakeup_later out_notify (Ok handler_res))
  in
  let trailers_handler = extract_status status_notify in
  let write_body =
    do_request ?trailers_handler:(Some trailers_handler) request
      ~response_handler
  in
  Lwt.async (fun () ->
      let+ handler_res = handler write_body read_body in
      Lwt.wakeup_later handler_res_notify handler_res);
  let* out in
  let+ status =
    if Lwt.is_sleeping status then
      Lwt.return (Grpc.Status.v Grpc.Status.Unknown)
    else status
  in
  match out with Error _ as e -> e | Ok out -> Ok (out, status)

module Rpc = struct
  type 'a handler =
    [ `write ] H2.Body.t -> [ `read ] H2.Body.t Lwt.t -> 'a Lwt.t

  let bidirectional_streaming ~f write_body read_body =
    let decoder_stream, decoder_push = Lwt_stream.create () in
    Lwt.async (fun () ->
        let+ read_body in
        Connection.grpc_recv_streaming read_body decoder_push);
    let encoder_stream, encoder_push = Lwt_stream.create () in
    Lwt.async (fun () ->
        Connection.grpc_send_streaming_client write_body encoder_stream);
    f encoder_push decoder_stream

  let client_streaming ~f =
    bidirectional_streaming ~f:(fun encoder_push decoder_stream ->
        let decoder = Lwt_stream.get decoder_stream in
        f encoder_push decoder)

  let server_streaming ~f enc =
    bidirectional_streaming ~f:(fun encoder_push decoder_stream ->
        (fun enc ->
          encoder_push (Some enc);
          encoder_push None)
          enc;
        f decoder_stream)

  let unary ~f enc =
    bidirectional_streaming ~f:(fun encoder_push decoder_stream ->
        (fun enc ->
          encoder_push (Some enc);
          encoder_push None)
          enc;
        let decoder = Lwt_stream.get decoder_stream in
        f decoder)
end
