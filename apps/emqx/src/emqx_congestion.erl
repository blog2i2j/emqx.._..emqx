%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_congestion).

-export([
    maybe_alarm_conn_congestion/3,
    cancel_alarms/3
]).

-elvis([{elvis_style, invalid_dynamic_call, #{ignore => [emqx_congestion]}}]).

-define(ALARM_CONN_CONGEST(Channel, Reason),
    list_to_binary(
        io_lib:format(
            "~ts/~ts/~ts",
            [
                Reason,
                emqx_channel:info(clientid, Channel),
                maps:get(
                    username,
                    emqx_channel:info(clientinfo, Channel),
                    <<"unknown_user">>
                )
            ]
        )
    )
).

-define(ALARM_CONN_INFO_KEYS, [
    socktype,
    sockname,
    peername,
    clientid,
    username,
    proto_name,
    proto_ver,
    connected_at,
    conn_state
]).
-define(ALARM_SOCK_STATS_KEYS, [send_pend, recv_cnt, recv_oct, send_cnt, send_oct]).
-define(ALARM_SOCK_OPTS_KEYS, [high_watermark, high_msgq_watermark, sndbuf, recbuf, buffer]).
-define(PROC_INFO_KEYS, [message_queue_len, memory, reductions]).
-define(ALARM_SENT(REASON), {alarm_sent, REASON}).
-define(ALL_ALARM_REASONS, [conn_congestion]).

maybe_alarm_conn_congestion(Socket, Transport, Channel) ->
    case is_alarm_enabled(Channel) of
        false ->
            ok;
        true ->
            case is_tcp_congested(Socket, Transport) of
                true -> alarm_congestion(Socket, Transport, Channel, conn_congestion);
                false -> cancel_alarm_congestion(Socket, Transport, Channel, conn_congestion)
            end
    end.

cancel_alarms(Socket, Transport, Channel) ->
    lists:foreach(
        fun(Reason) ->
            case has_alarm_sent(Reason) of
                true -> do_cancel_alarm_congestion(Socket, Transport, Channel, Reason);
                false -> ok
            end
        end,
        ?ALL_ALARM_REASONS
    ).

is_alarm_enabled(Channel) ->
    Zone = emqx_channel:info(zone, Channel),
    emqx_config:get_zone_conf(Zone, [conn_congestion, enable_alarm]).

alarm_congestion(Socket, Transport, Channel, Reason) ->
    case has_alarm_sent(Reason) of
        false ->
            do_alarm_congestion(Socket, Transport, Channel, Reason);
        true ->
            %% pretend we have sent an alarm again
            update_alarm_sent_at(Reason)
    end.

cancel_alarm_congestion(Socket, Transport, Channel, Reason) ->
    Zone = emqx_channel:info(zone, Channel),
    WontClearIn = emqx_config:get_zone_conf(Zone, [
        conn_congestion,
        min_alarm_sustain_duration
    ]),
    case has_alarm_sent(Reason) andalso long_time_since_last_alarm(Reason, WontClearIn) of
        true -> do_cancel_alarm_congestion(Socket, Transport, Channel, Reason);
        false -> ok
    end.

do_alarm_congestion(Socket, Transport, Channel, Reason) ->
    ok = update_alarm_sent_at(Reason),
    AlarmDetails = tcp_congestion_alarm_details(Socket, Transport, Channel),
    Message = io_lib:format("connection congested: ~0p", [AlarmDetails]),
    emqx_alarm:activate(?ALARM_CONN_CONGEST(Channel, Reason), AlarmDetails, Message),
    ok.

do_cancel_alarm_congestion(Socket, Transport, Channel, Reason) ->
    ok = remove_alarm_sent_at(Reason),
    AlarmDetails = tcp_congestion_alarm_details(Socket, Transport, Channel),
    Message = io_lib:format("connection congested: ~0p", [AlarmDetails]),
    emqx_alarm:ensure_deactivated(?ALARM_CONN_CONGEST(Channel, Reason), AlarmDetails, Message),
    ok.

is_tcp_congested(Socket, Transport) ->
    case Transport:getstat(Socket, [send_pend]) of
        {ok, [{send_pend, N}]} when N > 0 -> true;
        _ -> false
    end.

has_alarm_sent(Reason) ->
    case get_alarm_sent_at(Reason) of
        0 -> false;
        _ -> true
    end.
update_alarm_sent_at(Reason) ->
    erlang:put(?ALARM_SENT(Reason), timenow()),
    ok.
remove_alarm_sent_at(Reason) ->
    erlang:erase(?ALARM_SENT(Reason)),
    ok.
get_alarm_sent_at(Reason) ->
    case erlang:get(?ALARM_SENT(Reason)) of
        undefined -> 0;
        LastSentAt -> LastSentAt
    end.
long_time_since_last_alarm(Reason, WontClearIn) ->
    %% only sent clears when the alarm was not triggered in the last
    %% WontClearIn time
    case timenow() - get_alarm_sent_at(Reason) of
        Elapse when Elapse >= WontClearIn -> true;
        _ -> false
    end.

timenow() ->
    erlang:system_time(millisecond).

%%==============================================================================
%% Alarm message
%%==============================================================================
tcp_congestion_alarm_details(Socket, Transport, Channel) ->
    ProcInfo = process_info(self(), ?PROC_INFO_KEYS),
    BasicInfo = [{pid, list_to_binary(pid_to_list(self()))} | ProcInfo],
    Stat =
        case Transport:getstat(Socket, ?ALARM_SOCK_STATS_KEYS) of
            {ok, Stat0} -> Stat0;
            {error, _} -> []
        end,
    Opts =
        case Transport:getopts(Socket, ?ALARM_SOCK_OPTS_KEYS) of
            {ok, Opts0} -> Opts0;
            {error, _} -> []
        end,
    SockInfo = Stat ++ Opts,
    ConnInfo = [conn_info(Key, Channel) || Key <- ?ALARM_CONN_INFO_KEYS],
    maps:from_list(BasicInfo ++ ConnInfo ++ SockInfo).

conn_info(Key, Channel) when Key =:= sockname; Key =:= peername ->
    {IPStr, Port} = emqx_channel:info(Key, Channel),
    {Key, iolist_to_binary([inet:ntoa(IPStr), ":", integer_to_list(Port)])};
conn_info(Key, Channel) ->
    {Key, emqx_channel:info(Key, Channel)}.
