%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% @doc This module implements a per-shard singleton process
%% facilitating optimistic transactions. This process is dynamically
%% spawned on the leader node.
%%
%% Optimistic transaction leader tracks recent writes and verifies
%% transactions from the clients. Transactions containing reads that
%% may race with the recently updated topics are rejected. Valid
%% transactions are "cooked" and added to the buffer.
%%
%% Buffer is periodically flushed in a single call to the backend.
%%
%% Leader is also tasked with keeping and incrementing the transaction
%% serial for the pending transactions. The latest serial is committed
%% to the storage together with the batches.
%%
%% Potential split brain situations are handled optimistically: the
%% backend can reject flush request.
-module(emqx_ds_optimistic_tx).

-behaviour(gen_statem).

%% API:
-export([
    start_link/3,

    where/2,

    new_kv_tx_ctx/5,
    commit_kv_tx/3,
    tx_commit_outcome/1
]).

%% Behaviour callbacks
-export([
    init/1,
    terminate/3,
    handle_event/4,
    callback_mode/0
]).

-export_type([
    ctx/0,
    serial/0,
    runtime_config/0
]).

-include("emqx_ds.hrl").
-include("emqx_ds_builtin_tx.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%================================================================================
%% Type declarations
%%================================================================================

-type serial() :: integer().

-type batch() :: {emqx_ds:generation(), [_CookedTx]}.

%% Get the last committed transaction ID on the local replica
-callback otx_get_tx_serial(emqx_ds:db(), emqx_ds:shard()) ->
    {ok, serial()} | undefined.

%% Cook a raw transaction into a data structure that will be stored in
%% the buffer until flush.
-callback otx_prepare_tx(
    {emqx_ds:db(), emqx_ds:shard()},
    emqx_ds:generation(),
    _SerialBin :: binary(),
    emqx_ds:tx_ops(),
    _MiscOpts :: map()
) ->
    {ok, _CookedTx} | emqx_ds:error(_).

%% Commit a batch of cooked transactions to the storage.
-callback otx_commit_tx_batch(
    {emqx_ds:db(), emqx_ds:shard()},
    _OldSerial :: serial(),
    _NewSerial :: serial(),
    batch()
) ->
    ok | emqx_ds:error(_).

%% Lookup a value identified by topic and timestamp. This callback is
%% executed only on the leader node.
-callback otx_lookup_ttv(
    {emqx_ds:db(), emqx_ds:shard()},
    emqx_ds:generation(),
    emqx_ds:topic(),
    emqx_ds:time()
) ->
    {ok, binary()} | undefined | emqx_ds:error(_).

%% Configuration that can be changed in the runtime.
-type runtime_config() :: #{
    flush_interval := non_neg_integer(),
    idle_flush_interval := non_neg_integer(),
    conflict_window := pos_integer()
}.

%% Executed by the leader when it updates its runtime config
-callback otx_get_runtime_config(emqx_ds:db()) -> runtime_config().

%% Executed in the leader process when it attempts to step up.
-callback otx_become_leader(emqx_ds:db(), emqx_ds:shard()) ->
    {ok, serial()} | {error, _}.

%% Executed by the readers
-callback otx_get_leader(emqx_ds:db(), emqx_ds:shard()) -> pid() | undefined.

-type ctx() :: #kv_tx_ctx{}.

-define(name(DB, SHARD), {n, l, {?MODULE, DB, SHARD}}).
-define(via(DB, SHARD), {via, gproc, ?name(DB, SHARD)}).

%% States
-define(initial, initial).
-define(leader(SUBSTATE), {leader, SUBSTATE}).
-define(idle, idle).
-define(pending, pending).

%% Timeouts
-define(timeout_initialize, timeout_initialize).
%%   Flush pending transactions to the storage:
-define(timeout_flush, timout_flush).

-record(gen_data, {
    dirty :: emqx_ds_tx_conflict_trie:t(),
    buffer = [],
    pending_replies = []
}).

-type gen_data() :: #gen_data{}.

-type generations() :: #{emqx_ds:generation() => gen_data()}.

-record(d, {
    db :: emqx_ds:db(),
    shard :: emqx_ds:shard(),
    cbm :: module(),
    flush_interval :: pos_integer(),
    idle_flush_interval :: pos_integer(),
    rotate_interval :: pos_integer(),
    last_rotate_ts,
    serial :: non_neg_integer() | undefined,
    committed_serial :: non_neg_integer() | undefined,
    gens = #{} :: generations()
}).

%%================================================================================
%% API functions
%%================================================================================

-spec where(emqx_ds:db(), emqx_ds:shard()) -> pid() | undefined.
where(DB, Shard) ->
    gproc:where(?name(DB, Shard)).

-spec start_link(emqx_ds:db(), emqx_ds:shard(), module()) -> {ok, pid()}.
start_link(DB, Shard, CBM) ->
    gen_statem:start_link(?via(DB, Shard), ?MODULE, [DB, Shard, CBM], []).

-spec new_kv_tx_ctx(
    module(), emqx_ds:db(), emqx_ds:shard(), emqx_ds:generation(), emqx_ds:transaction_opts()
) -> {ok, ctx()} | emqx_ds:error(_).
new_kv_tx_ctx(CBM, DB, Shard, Generation, Opts) ->
    maybe
        Leader = CBM:otx_get_leader(DB, Shard),
        true ?= is_pid(Leader),
        {ok, Serial} ?= CBM:otx_get_tx_serial(DB, Shard),
        Ctx = #kv_tx_ctx{
            shard = Shard,
            leader = Leader,
            serial = Serial,
            generation = Generation,
            opts = Opts
        },
        {ok, Ctx}
    else
        _ ->
            ?err_rec(leader_down)
    end.

commit_kv_tx(DB, Ctx = #kv_tx_ctx{opts = #{timeout := Timeout}}, Ops) ->
    ?tp(emqx_ds_optimistic_tx_commit_begin, #{db => DB, ctx => Ctx, ops => Ops}),
    #kv_tx_ctx{leader = Leader} = Ctx,
    Ref = monitor(process, Leader),
    %% Note: currently timer is not canceled when commit abort is
    %% signalled via the monitor message (i.e. when the leader process
    %% is down). In this case the caller _will_ receive double `DOWN'.
    %% There's no trivial way to fix it. It's up to the client to
    %% track the pending transactions and ignore unexpected commit
    %% notifications.
    TRef = emqx_ds_lib:send_after(Timeout, self(), tx_timeout_msg(Ref)),
    gen_statem:cast(Leader, #ds_tx{
        ctx = Ctx, ops = Ops, from = self(), ref = Ref, meta = TRef
    }),
    Ref.

-spec tx_commit_outcome(term()) -> {ok, emqx_ds:tx_serial()} | emqx_ds:error(_).
tx_commit_outcome(Reply) ->
    case Reply of
        ?ds_tx_commit_ok(Ref, TRef, Serial) ->
            emqx_ds_lib:cancel_timer(TRef, tx_timeout_msg(Ref)),
            {ok, Serial};
        ?ds_tx_commit_error(Ref, TRef, Class, Info) ->
            emqx_ds_lib:cancel_timer(TRef, tx_timeout_msg(Ref)),
            {error, Class, Info};
        {'DOWN', _Ref, Type, Object, Info} ->
            %% This is likely a real monitor message. It doesn't contain TRef,
            %% so the caller will receive the timeout message after the fact.
            %% There's not much we can do about it.
            ?err_unrec({Type, Object, Info})
    end.

%%================================================================================
%% Behavior callbacks
%%================================================================================

callback_mode() ->
    [handle_event_function, state_enter].

init([DB, Shard, CBM]) ->
    erlang:process_flag(trap_exit, true),
    logger:update_process_metadata(#{db => DB, shard => Shard}),
    ?tp(info, ds_otx_start, #{db => DB, shard => Shard}),
    #{
        flush_interval := FI,
        idle_flush_interval := IFI,
        conflict_window := CW
    } = CBM:otx_get_runtime_config(DB),
    D = #d{
        db = DB,
        shard = Shard,
        cbm = CBM,
        rotate_interval = CW,
        last_rotate_ts = erlang:monotonic_time(millisecond),
        flush_interval = FI,
        idle_flush_interval = IFI
    },
    {ok, ?initial, D, {state_timeout, 0, ?timeout_initialize}}.

terminate(Reason, State, _Data) ->
    Level =
        case Reason =:= normal orelse Reason =:= shutdown of
            true ->
                info;
            false ->
                %% Sleep some to prevent a hot restart loop
                timer:sleep(1_000),
                error
        end,
    ?tp(Level, ds_otx_terminate, #{state => State, reason => Reason}).

handle_event(info, {'EXIT', _, _Reason}, _State, _Data) ->
    {stop, shutdown};
handle_event(enter, _OldState, ?leader(?pending), #d{flush_interval = T}) ->
    %% Schedule unconditional flush after the given interval:
    {keep_state_and_data, {state_timeout, T, ?timeout_flush}};
handle_event(enter, _, _, _) ->
    keep_state_and_data;
handle_event(state_timeout, ?timeout_initialize, ?initial, D) ->
    async_init(D);
handle_event(ET, Evt, ?initial, _) ->
    ?tp(warning, unexpected_event_in_initial_state, #{ET => Evt}),
    {keep_state_and_data, postpone};
handle_event(cast, Tx = #ds_tx{}, ?leader(State), D0 = #d{idle_flush_interval = IdleInterval}) ->
    %% Enqueue transaction commit:
    case handle_tx(D0, Tx) of
        {ok, D} ->
            %% Schedule early flush if the shard is idle:
            Timeout = {timeout, IdleInterval, ?timeout_flush},
            case State of
                ?idle ->
                    {next_state, ?leader(?pending), D, Timeout};
                _ ->
                    {keep_state, D, Timeout}
            end;
        aborted ->
            keep_state_and_data
    end;
handle_event(cast, #ds_tx{from = From, ref = Ref, meta = Meta}, _Other, _) ->
    reply_error(From, Ref, Meta, recoverable, not_the_leader),
    keep_state_and_data;
handle_event(ET, ?timeout_flush, ?leader(_State), D0) when ET =:= state_timeout; ET =:= timeout ->
    %% Execute flush. After flushing the buffer it's safe to rotate
    %% the conflict tree.
    D = maybe_rotate(flush(D0)),
    {next_state, ?leader(?idle), D};
handle_event(ET, Event, State, _D) ->
    ?tp(
        error,
        emqx_ds_tx_serializer_unknown_event,
        #{ET => Event, state => State}
    ),
    keep_state_and_data.

%%================================================================================
%% Internal functions
%%================================================================================

async_init(D = #d{db = DB, shard = Shard, cbm = CBM}) ->
    maybe
        {ok, Serial} ?= CBM:otx_become_leader(DB, Shard),
        %% Issue a dummy transaction to trigger metadata update:
        ok ?= CBM:otx_commit_tx_batch({DB, Shard}, Serial, Serial, []),
        ?tp(info, ds_otx_up, #{serial => Serial, db => DB, shard => Shard}),
        {next_state, ?leader(?idle), D#d{
            serial = Serial,
            committed_serial = Serial
        }}
    else
        Err ->
            {stop, {init_failed, Err}}
    end.

handle_tx(
    D = #d{
        db = DB,
        shard = Shard,
        cbm = CBM,
        serial = Serial,
        committed_serial = SafeToReadSerial,
        gens = Gens
    },
    Tx
) ->
    DBShard = {DB, Shard},
    #ds_tx{ref = TxRef, ctx = #kv_tx_ctx{generation = Gen}} = Tx,
    ?tp(
        emqx_ds_optimistic_tx_commit_received,
        #{
            shard => DBShard,
            serial => Serial,
            committed_serial => SafeToReadSerial,
            ref => TxRef,
            tx => Tx
        }
    ),
    case Gens of
        #{Gen := GS0} ->
            ok;
        #{} ->
            GS0 = #gen_data{dirty = emqx_ds_tx_conflict_trie:new(Serial, infinity)}
    end,
    PresumedCommitSerial = Serial + 1,
    case try_commit(DBShard, Gen, CBM, SafeToReadSerial, PresumedCommitSerial, Tx, GS0) of
        {ok, GS} ->
            ?tp(emqx_ds_optimistic_tx_commit_pending, #{ref => TxRef}),
            {ok, D#d{
                serial = PresumedCommitSerial,
                gens = Gens#{Gen => GS}
            }};
        aborted ->
            aborted
    end.

try_commit(
    DBShard,
    Gen,
    CBM,
    SafeToReadSerial,
    PresumedCommitSerial,
    Tx,
    GS = #gen_data{dirty = Dirty0, buffer = Buff, pending_replies = Pending}
) ->
    #ds_tx{
        ctx = Ctx,
        ops = Ops,
        from = From,
        ref = Ref,
        meta = Meta
    } = Tx,
    #kv_tx_ctx{serial = TxStartSerial} = Ctx,
    maybe
        ok ?= check_conflicts(Dirty0, TxStartSerial, SafeToReadSerial, Ops),
        ok ?= verify_preconditions(DBShard, CBM, Gen, Ops),
        {ok, CookedTx} ?=
            CBM:otx_prepare_tx(
                DBShard, Gen, serial_bin(PresumedCommitSerial), Ops, #{}
            ),
        Dirty = update_dirty(PresumedCommitSerial, Ops, Dirty0),
        {ok, GS#gen_data{
            dirty = Dirty,
            buffer = [CookedTx | Buff],
            pending_replies = [{From, Ref, Meta, PresumedCommitSerial} | Pending]
        }}
    else
        {error, Class, Error} ->
            ?tp(
                debug,
                emqx_ds_optimistic_tx_commit_abort,
                #{
                    ref => Ref, ec => Class, reason => Error, stage => prepare
                }
            ),
            reply_error(From, Ref, Meta, Class, Error),
            aborted
    end.

update_dirty(Serial, Ops, Dirty0) ->
    %% Mark all deleted topics as dirty:
    Dirty1 = lists:foldl(
        fun(TF, Acc) ->
            emqx_ds_tx_conflict_trie:push(
                emqx_ds_tx_conflict_trie:topic_filter_to_conflict_domain(TF),
                Serial,
                Acc
            )
        end,
        Dirty0,
        maps:get(?ds_tx_delete_topic, Ops, [])
    ),
    %% Mark written topics as dirty:
    lists:foldl(
        fun({TF, _TS, _Val}, Acc) ->
            emqx_ds_tx_conflict_trie:push(TF, Serial, Acc)
        end,
        Dirty1,
        maps:get(?ds_tx_write, Ops, [])
    ).

flush(
    D = #d{
        db = DB, shard = Shard, cbm = CBM, committed_serial = SerCtl, serial = Serial, gens = Gens0
    }
) ->
    DBShard = {DB, Shard},
    ?tp(debug, emqx_ds_optimistic_tx_flush, #{}),
    Batch = make_batch(Gens0),
    Result = CBM:otx_commit_tx_batch(DBShard, SerCtl, Serial, Batch),
    Gens = clean_buffers_and_reply(Result, Gens0),
    #{flush_interval := FI, idle_flush_interval := IFI, conflict_window := CW} = CBM:otx_get_runtime_config(
        DB
    ),
    case Result of
        ok ->
            D#d{
                committed_serial = Serial,
                gens = Gens,
                flush_interval = FI,
                idle_flush_interval = IFI,
                rotate_interval = CW
            };
        _ ->
            exit({flush_failed, #{db => DB, shard => Shard, result => Result}})
    end.

-spec make_batch(generations()) -> batch().
make_batch(Generations) ->
    maps:fold(
        fun(Generation, #gen_data{buffer = Buf}, Acc) ->
            [{Generation, Buf} | Acc]
        end,
        [],
        Generations
    ).

-spec clean_buffers_and_reply(ok | emqx_ds:error(_), generations()) -> generations().
clean_buffers_and_reply(Reply, Generations) ->
    maps:map(
        fun(_, GenData = #gen_data{pending_replies = Waiting}) ->
            _ =
                case Reply of
                    ok ->
                        [
                            reply_success(From, Ref, Meta, CommitSerial)
                         || {From, Ref, Meta, CommitSerial} <- Waiting
                        ];
                    {error, Class, Err} ->
                        [
                            reply_error(From, Ref, Meta, Class, Err)
                         || {From, Ref, Meta, _CommitSerial} <- Waiting
                        ]
                end,
            GenData#gen_data{
                buffer = [],
                pending_replies = []
            }
        end,
        Generations
    ).

serial_bin(A) ->
    <<A:128>>.

maybe_rotate(D = #d{rotate_interval = RI, last_rotate_ts = LastRotTS}) ->
    case erlang:monotonic_time(millisecond) - LastRotTS > RI of
        true ->
            rotate(D);
        false ->
            D
    end.

rotate(D = #d{gens = Gens0}) ->
    Gens = maps:map(
        fun(_, GS = #gen_data{dirty = Dirty}) ->
            GS#gen_data{
                dirty = emqx_ds_tx_conflict_trie:rotate(Dirty)
            }
        end,
        Gens0
    ),
    D#d{
        gens = Gens,
        last_rotate_ts = erlang:monotonic_time(millisecond)
    }.

check_conflicts(Dirty, TxStartSerial, SafeToReadSerial, Ops) ->
    maybe
        ok ?= do_check_conflicts(Dirty, TxStartSerial, maps:get(?ds_tx_read, Ops, [])),
        %% Deletion of topics involves scanning of the storage. We
        %% can't do it when there is potentially buffered data:
        ok ?= do_check_conflicts(Dirty, SafeToReadSerial, maps:get(?ds_tx_delete_topic, Ops, [])),
        %% Verifying precondition requires reading from the storage
        %% too. Make sure we don't ignore the cache:
        ExpectedTopics = [Topic || {Topic, _, _} <- maps:get(?ds_tx_expected, Ops, [])],
        ok ?= do_check_conflicts(Dirty, SafeToReadSerial, ExpectedTopics),
        UnexpectedTopics = [Topic || {Topic, _} <- maps:get(?ds_tx_unexpected, Ops, [])],
        ok ?= do_check_conflicts(Dirty, SafeToReadSerial, UnexpectedTopics)
    end.

do_check_conflicts(Dirty, Serial, Topics) ->
    Errors = lists:foldl(
        fun(ReadTF, Acc) ->
            case
                emqx_ds_tx_conflict_trie:is_dirty(
                    emqx_ds_tx_conflict_trie:topic_filter_to_conflict_domain(ReadTF),
                    Serial,
                    Dirty
                )
            of
                false ->
                    Acc;
                true ->
                    [{ReadTF, Serial} | Acc]
            end
        end,
        [],
        Topics
    ),
    case Errors of
        [] ->
            ok;
        _ ->
            ?err_rec({read_conflict, Errors})
    end.

verify_preconditions(DBShard, CBM, GenId, Ops) ->
    %% Verify expected values:
    Unrecoverable0 = lists:foldl(
        fun({Topic, Time, ExpectedValue}, Acc) ->
            case CBM:otx_lookup_ttv(DBShard, GenId, Topic, Time) of
                {ok, Value} when
                    ExpectedValue =:= '_';
                    ExpectedValue =:= Value
                ->
                    Acc;
                {ok, Value} ->
                    [#{topic => Topic, expected => ExpectedValue, ts => Time, got => Value} | Acc];
                undefined ->
                    [
                        #{topic => Topic, expected => ExpectedValue, ts => Time, got => undefined}
                        | Acc
                    ]
            end
        end,
        [],
        maps:get(?ds_tx_expected, Ops, [])
    ),
    %% Verify unexpected values:
    Unrecoverable = lists:foldl(
        fun({Topic, Time}, Acc) ->
            case CBM:otx_lookup_ttv(DBShard, GenId, Topic, Time) of
                undefined ->
                    Acc;
                {ok, Value} ->
                    [#{topic => Topic, ts => Time, unexpected => Value} | Acc]
            end
        end,
        Unrecoverable0,
        maps:get(?ds_tx_unexpected, Ops, [])
    ),
    case Unrecoverable of
        [] ->
            ok;
        _ ->
            ?err_unrec({precondition_failed, Unrecoverable})
    end.

tx_timeout_msg(Ref) ->
    ?ds_tx_commit_error(Ref, undefined, unrecoverable, commit_timeout).

reply_success(From, Ref, Meta, Serial) ->
    ?tp(
        emqx_ds_optimistic_tx_commit_success,
        #{client => From, ref => Ref, meta => Meta, serial => Serial}
    ),
    From ! ?ds_tx_commit_ok(Ref, Meta, serial_bin(Serial)),
    ok.

reply_error(From, Ref, Meta, Class, Error) ->
    ?tp(
        debug,
        emqx_ds_optimistic_tx_commit_abort,
        #{client => From, ref => Ref, meta => Meta, ec => Class, reason => Error, stage => final}
    ),
    From ! ?ds_tx_commit_error(Ref, Meta, Class, Error),
    ok.

%%================================================================================
%% Tests
%%================================================================================
