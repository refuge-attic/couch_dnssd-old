%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011 Andrew Tunnell-Jones. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(couch_dnssd).
-behaviour(gen_server).

-include("couch/include/couch_db.hrl").

-export([start_link/0, handle_dnssd_req/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {local_only, reg_ref, browse_ref}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

handle_dnssd_req(#httpd{method='GET', path_parts=[_]} = Req) ->
    %% one-fragment - return all services
    {ok, ServicesList} = gen_server:call(?SERVER, list_services),
    couch_httpd:send_json(Req, [{[{<<"name">>, Name}, {<<"domain">>, Domain}]}
				|| {Name, _Type, Domain} <- ServicesList ]);
handle_dnssd_req(#httpd{method='GET', path_parts=[_,QDomain]} = Req) ->
    %% two-fragments - return all services in a domain
    FilterFun = build_domain_filter_fun(QDomain),
    {ok, ServicesList} = gen_server:call(?SERVER, list_services),
    couch_httpd:send_json(Req, [{[{<<"name">>, Name}, {<<"domain">>, Domain}]}
				|| {Name, _Type, Domain} <- ServicesList,
				   FilterFun(Domain) ]);
handle_dnssd_req(#httpd{method='GET', path_parts=[_, QDomain, QName]} = Req) ->
    %% three-fragments - resolve a service
    case dnssd:resolve_sync(QName, "_http._tcp", QDomain) of
	{ok, {Host, Port, _Params}} ->
	    couch_httpd:send_json(Req, {[{<<"hostname">>, Host},
					 {<<"port">>, Port},
					 {<<"params">>, _Params}]});
	{error, timeout} -> send_not_found(Req)
    end;
handle_dnssd_req(#httpd{} = Req) -> send_not_found(Req).

init([]) ->
    ok = ensure_dnssd_started(),
    {ok, Ref} = dnssd:browse("_http._tcp,_couchdb"),
    LocalOnly = is_local_only(),
    State = #state{local_only = LocalOnly, browse_ref = Ref},
    init(State);
init(#state{local_only = true} = State) ->
    {ok, State};
init(#state{local_only = false} = State) ->
    {ok, Ref} = dnssd:register(service_name(), "_http._tcp,_couchdb",
			       httpd_port(), [{path, service_path()}]),
    NewState = State#state{reg_ref = Ref},
    {ok, NewState}.

handle_call(list_services, _From, #state{} = State) ->
    {ok, RegResults} = dnssd:results(State#state.reg_ref),
    {ok, BrowseResults} = dnssd:results(State#state.browse_ref),
    Services = BrowseResults -- RegResults,
    Reply = {ok, Services},
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({dnssd, Ref, {browse, Change, Result}}, #state{browse_ref = Ref}) ->
    ?LOG_DEBUG(?MODULE_STRING " browse ~s: ~p~n", [Change, Result]),
    {noreply, state};
handle_info({dnssd, Ref, {register, Change, Result}}, #state{reg_ref = Ref}) ->
    ?LOG_DEBUG(?MODULE_STRING " register ~s: ~p~n", [Change, Result]),
    {noreply, state};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

send_not_found(Req) ->
    {ErrNo, ErrorStr, ReasonStr} = couch_httpd:error_info(not_found),
    couch_httpd:send_error(Req, ErrNo, ErrorStr, ReasonStr).

build_domain_filter_fun(Domain) when is_binary(Domain) ->
    build_domain_filter_fun(binary_to_list(Domain));
build_domain_filter_fun(Domain) when is_list(Domain) ->
    DotLessDomain = list_to_binary(strip:strip(Domain, right, $.)),
    DottedDomain = list_to_binary([DotLessDomain, $.]),
    fun(X) -> X =:= DotLessDomain orelse X =:= DottedDomain end.

ensure_dnssd_started() ->
    case application:start(dnssd) of
	{error, {already_started, dnssd}} -> ok;
	Other -> Other
    end.

is_local_only() ->
    case couch_config:get(<<"httpd">>, <<"bind_address">>) of
	"127." ++ _ -> true;
	"::1" -> true;
	_ -> false
    end.

httpd_port() ->
    PortStr = couch_config:get(<<"httpd">>, <<"port">>),
    list_to_integer(PortStr).

service_path() ->
    case couch_config:get(<<"dnssd">>, <<"path">>) of
	Path when is_list(Path) andalso length(Path) < 251 ->
	    Path;
	_ -> "/_utils/"
    end.

service_name() ->
    case couch_config:get(<<"dnssd">>, <<"name">>) of
	ServiceName
	  when is_list(ServiceName) andalso length(ServiceName) < 64 ->
	    ServiceName;
	_ ->
	    build_service_name()
    end.

build_service_name() ->
    Prefix = case username() of
		 {ok, Username} ->
		     case lists:reverse(Username) of
			 "s" ++ _ -> Username ++ "' CouchDB on ";
			 _ -> Username ++ "'s CouchDB on "
		     end;
		 _ -> "CouchDB on "
	     end,
    PrefixLen = length(Prefix),
    case inet:gethostname() of
	{ok, Hostname} ->
	    HostnameLen = length(Hostname),
	    if HostnameLen + PrefixLen < 64 ->
		    Prefix ++ Hostname;
	       true -> ""
	    end;
	_ -> ""
    end.

username() ->
    case os:getenv("USER") of
	Username when is_list(Username) ->
	    {ok, Username};
	_ ->
	    case os:getenv("USERNAME") of
		Username when is_list(Username) ->
		    {ok, Username};
		_ ->
		    undefined
	    end
    end.
