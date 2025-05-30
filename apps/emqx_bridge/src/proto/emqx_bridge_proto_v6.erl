%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_proto_v6).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,

    list_bridges_on_nodes/1,
    restart_bridge_to_node/3,
    start_bridge_to_node/3,
    stop_bridge_to_node/3,
    lookup_from_all_nodes/3,
    get_metrics_from_all_nodes/3,
    restart_bridges_to_all_nodes/3,
    start_bridges_to_all_nodes/3,
    stop_bridges_to_all_nodes/3,

    %% introduced in v6
    v2_lookup_from_all_nodes_v6/4,
    v2_list_bridges_on_nodes_v6/2,
    v2_get_metrics_from_all_nodes_v6/4,
    v2_start_bridge_on_node_v6/4,
    v2_start_bridge_on_all_nodes_v6/4
]).

-include_lib("emqx/include/bpapi.hrl").

-define(TIMEOUT, 15000).

introduced_in() ->
    "5.5.0".

-spec list_bridges_on_nodes([node()]) ->
    emqx_rpc:erpc_multicall([emqx_resource:resource_data()]).
list_bridges_on_nodes(Nodes) ->
    erpc:multicall(Nodes, emqx_bridge, list, [], ?TIMEOUT).

-type key() :: atom() | binary() | [byte()].

-spec restart_bridge_to_node(node(), key(), key()) ->
    term().
restart_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        restart,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec start_bridge_to_node(node(), key(), key()) ->
    term().
start_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        start,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec stop_bridge_to_node(node(), key(), key()) ->
    term().
stop_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        stop,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec restart_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(ok).
restart_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        restart,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec start_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(ok).
start_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        start,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec stop_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(ok).
stop_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        stop,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec lookup_from_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(term()).
lookup_from_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_api,
        lookup_from_local_node,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec get_metrics_from_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(emqx_metrics_worker:metrics()).
get_metrics_from_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_api,
        get_metrics_from_local_node,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

%%--------------------------------------------------------------------------------
%% introduced in v6
%%--------------------------------------------------------------------------------

%% V2 Calls
-spec v2_lookup_from_all_nodes_v6([node()], emqx_bridge_v2:root_cfg_key(), key(), key()) ->
    emqx_rpc:erpc_multicall(term()).
v2_lookup_from_all_nodes_v6(Nodes, ConfRootKey, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_v2_api,
        lookup_from_local_node_v6,
        [ConfRootKey, BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec v2_list_bridges_on_nodes_v6([node()], emqx_bridge_v2:root_cfg_key()) ->
    emqx_rpc:erpc_multicall([emqx_resource:resource_data()]).
v2_list_bridges_on_nodes_v6(Nodes, ConfRootKey) ->
    erpc:multicall(Nodes, emqx_bridge_v2, list, [ConfRootKey], ?TIMEOUT).

-spec v2_get_metrics_from_all_nodes_v6([node()], emqx_bridge_v2:root_cfg_key(), key(), key()) ->
    emqx_rpc:erpc_multicall(term()).
v2_get_metrics_from_all_nodes_v6(Nodes, ConfRootKey, ActionType, ActionName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_v2_api,
        get_metrics_from_local_node_v6,
        [ConfRootKey, ActionType, ActionName],
        ?TIMEOUT
    ).

-spec v2_start_bridge_on_all_nodes_v6([node()], emqx_bridge_v2:root_cfg_key(), key(), key()) ->
    emqx_rpc:erpc_multicall(ok).
v2_start_bridge_on_all_nodes_v6(Nodes, ConfRootKey, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_v2,
        start,
        [ConfRootKey, BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec v2_start_bridge_on_node_v6(node(), emqx_bridge_v2:root_cfg_key(), key(), key()) ->
    term().
v2_start_bridge_on_node_v6(Node, ConfRootKey, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_v2,
        start,
        [ConfRootKey, BridgeType, BridgeName],
        ?TIMEOUT
    ).
