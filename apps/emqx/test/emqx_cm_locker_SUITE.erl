%%--------------------------------------------------------------------
%% Copyright (c) 2019-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_cm_locker_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start([emqx], #{work_dir => emqx_cth_suite:work_dir(Config)}),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    emqx_cth_suite:stop(proplists:get_value(apps, Config)).

t_start_link(_) ->
    emqx_cm_locker:start_link().

t_trans(_) ->
    ok = emqx_cm_locker:trans(undefined, fun(_) -> ok end),
    ok = emqx_cm_locker:trans(<<"clientid">>, fun(_) -> ok end).

t_lock_unlock(_) ->
    {true, _} = emqx_cm_locker:lock(<<"clientid">>),
    {true, _} = emqx_cm_locker:lock(<<"clientid">>),
    {true, _} = emqx_cm_locker:unlock(<<"clientid">>),
    {true, _} = emqx_cm_locker:unlock(<<"clientid">>).
