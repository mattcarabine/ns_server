%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc implementation of builtin and saslauthd users

-module(menelaus_users).

-include("ns_config.hrl").
-include("rbac.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([get_users/1,
         store_user/4,
         delete_user/1,
         authenticate/2,
         get_auth_infos/1,
         get_roles/2,
         get_user_name/2,
         upgrade_to_4_5/1]).

-spec get_users(ns_config()) -> [{rbac_identity(), []}].
get_users(Config) ->
    ns_config:search(Config, user_roles, []).

build_auth(_Identity, undefined, _Users) ->
    [];
build_auth({User, _} = Identity, Password, Users) ->
    case proplists:get_value(Identity, Users) of
        undefined ->
            [{authentication, build_auth(User, Password)}];
        Props ->
            Auth = get_auth_info(Props),
            {Salt, Mac} = get_salt_and_mac(Auth),
            case get_memcached_auth(Auth) =:= undefined orelse
                ns_config_auth:hash_password(Salt, Password) =/= Mac of
                false ->
                    [{authentication, Auth}];
                true ->
                    [{authentication, build_auth(User, Password)}]
            end
    end.

build_auth(User, Password) ->
    [MemcachedAuth] = get_memcached_auth_info([{User, Password}]),
    [{ns_server, ns_config_auth:hash_password(Password)},
     {memcached, MemcachedAuth}].

-spec store_user(rbac_identity(), rbac_user_name(), rbac_password(), [rbac_role()]) -> run_txn_return().
store_user(Identity, Name, Password, Roles) ->
    Props = case Name of
                undefined ->
                    [];
                _ ->
                    [{name, Name}]
            end,
    ns_config:run_txn(
      fun (Config, SetFn) ->
              Users = get_users(Config),
              NewProps = [{roles, Roles} | Props] ++ build_auth(Identity, Password, Users),

              case menelaus_roles:validate_roles(Roles, Config) of
                  ok ->
                      NewUsers = lists:keystore(Identity, 1, Users, {Identity, NewProps}),
                      {commit, SetFn(user_roles, NewUsers, Config)};
                  Error ->
                      {abort, Error}
              end
      end).

-spec delete_user(rbac_identity()) -> run_txn_return().
delete_user(Identity) ->
    ns_config:run_txn(
      fun (Config, SetFn) ->
              case ns_config:search(Config, user_roles) of
                  false ->
                      {abort, {error, not_found}};
                  {value, Users} ->
                      case lists:keytake(Identity, 1, Users) of
                          false ->
                              {abort, {error, not_found}};
                          {value, _, NewUsers} ->
                              {commit, SetFn(user_roles, NewUsers, Config)}
                      end
              end
      end).

get_auth_info(Props) ->
    proplists:get_value(authentication, Props).

get_salt_and_mac(Auth) ->
    proplists:get_value(ns_server, Auth).

get_memcached_auth(Auth) ->
    proplists:get_value(memcached, Auth).

-spec authenticate(rbac_user_id(), rbac_password()) -> boolean().
authenticate(Username, Password) ->
    Users = get_users(ns_config:latest()),
    case proplists:get_value({Username, builtin}, Users) of
        undefined ->
            false;
        Props ->
            {Salt, Mac} = get_salt_and_mac(get_auth_info(Props)),
            ns_config_auth:hash_password(Salt, Password) =:= Mac
    end.

-spec get_auth_infos(ns_config()) -> [{rbac_identity(), term()}].
get_auth_infos(Config) ->
    Users = get_users(Config),
    [{{Username, builtin}, get_salt_and_mac(get_auth_info(Props))} ||
        {{Username, builtin}, Props} <- Users].

-spec get_roles(ns_config(), rbac_identity()) -> [rbac_role()].
get_roles(Config, Identity) ->
    Props = ns_config:search_prop(Config, user_roles, Identity, []),
    proplists:get_value(roles, Props, []).

-spec get_user_name(ns_config(), rbac_identity()) -> rbac_user_name().
get_user_name(Config, Identity) ->
    Props = ns_config:search_prop(Config, user_roles, Identity, []),
    proplists:get_value(name, Props).

collect_result(Port, Acc) ->
    receive
        {Port, {exit_status, Status}} ->
            {Status, lists:flatten(lists:reverse(Acc))};
        {Port, {data, Msg}} ->
            collect_result(Port, [Msg | Acc])
    end.

get_memcached_auth_info(UserPasswords) ->
    Iterations = ns_config:read_key_fast(memcached_password_hash_iterations, 4000),
    Port = ns_ports_setup:run_cbsasladm(Iterations),
    lists:foreach(
      fun ({User, Password}) ->
              PasswordStr = User ++ " " ++ Password ++ "\n",
              Port ! {self(), {command, list_to_binary(PasswordStr)}}
      end, UserPasswords),
    Port ! {self(), {command, <<"\n">>}},
    {0, Json} = collect_result(Port, []),
    {struct, [{<<"users">>, Infos}]} = mochijson2:decode(Json),
    Infos.

collect_users(asterisk, _Role, Dict) ->
    Dict;
collect_users([], _Role, Dict) ->
    Dict;
collect_users([User | Rest], Role, Dict) ->
    NewDict = dict:update(User, fun (Roles) ->
                                        ordsets:add_element(Role, Roles)
                                end, ordsets:from_list([Role]), Dict),
    collect_users(Rest, Role, NewDict).

-spec upgrade_to_4_5(ns_config()) -> [{set, user_roles, _}].
upgrade_to_4_5(Config) ->
    case ns_config:search(Config, saslauthd_auth_settings) of
        false ->
            [];
        {value, Props} ->
            case proplists:get_value(enabled, Props, false) of
                false ->
                    [];
                true ->
                    Dict = dict:new(),
                    Dict1 = collect_users(proplists:get_value(admins, Props, []), admin, Dict),
                    Dict2 = collect_users(proplists:get_value(roAdmins, Props, []), ro_admin, Dict1),
                    [{set, user_roles,
                      lists:map(fun ({User, Roles}) ->
                                        {{binary_to_list(User), saslauthd},
                                         [{roles, ordsets:to_list(Roles)}]}
                                end, dict:to_list(Dict2))}]
            end
    end.

upgrade_to_4_5_test() ->
    Config = [[{saslauthd_auth_settings,
                [{enabled,true},
                 {admins,[<<"user1">>, <<"user2">>, <<"user1">>, <<"user3">>]},
                 {roAdmins,[<<"user4">>, <<"user1">>]}]}]],
    UserRoles = [{{"user1", saslauthd}, [{roles, [admin, ro_admin]}]},
                 {{"user2", saslauthd}, [{roles, [admin]}]},
                 {{"user3", saslauthd}, [{roles, [admin]}]},
                 {{"user4", saslauthd}, [{roles, [ro_admin]}]}],
    Upgraded = upgrade_to_4_5(Config),
    ?assertMatch([{set, user_roles, _}], Upgraded),
    [{set, user_roles, UpgradedUserRoles}] = Upgraded,
    ?assertMatch(UserRoles, lists:sort(UpgradedUserRoles)).

upgrade_to_4_5_asterisk_test() ->
    Config = [[{saslauthd_auth_settings,
                [{enabled,true},
                 {admins, asterisk},
                 {roAdmins,[<<"user1">>]}]}]],
    UserRoles = [{{"user1", saslauthd}, [{roles, [ro_admin]}]}],
    Upgraded = upgrade_to_4_5(Config),
    ?assertMatch([{set, user_roles, _}], Upgraded),
    [{set, user_roles, UpgradedUserRoles}] = Upgraded,
    ?assertMatch(UserRoles, lists:sort(UpgradedUserRoles)).
