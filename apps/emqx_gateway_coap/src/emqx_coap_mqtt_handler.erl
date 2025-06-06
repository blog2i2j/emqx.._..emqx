%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_coap_mqtt_handler).

-include("emqx_coap.hrl").

-export([handle_request/4]).
-import(emqx_coap_message, [response/2, response/3]).
-import(emqx_coap_medium, [reply/2]).

handle_request([<<"connection">>], #coap_message{method = Method} = Msg, _Ctx, _CInfo) ->
    handle_method(Method, Msg);
handle_request(_, Msg, _, _) ->
    reply({error, bad_request}, Msg).

handle_method(put, Msg) ->
    reply({ok, changed}, Msg);
handle_method(post, Msg) ->
    #{connection => {open, Msg}};
handle_method(delete, Msg) ->
    #{connection => {close, Msg}};
handle_method(_, Msg) ->
    reply({error, method_not_allowed}, Msg).
