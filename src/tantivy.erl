-module(tantivy).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% apis
-export([child_spec/1, start_link/1, add/2, remove/1, update/2, search/2]).
-export([init/1, terminate/2, handle_call/3, handle_info/2, handle_cast/2]).

%% the data record to hold server state
-record(port_state, { port :: port(),
		     seq = 0 :: integer(),
		     map = #{} :: map() }).

%% client side apis
start_link(Command) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Command, []).

child_spec([{command, Command}]) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, [Command]},
      type => worker}.

add(Id, Doc) -> cast({add, Id, Doc}).

remove(Id) -> cast({remove, Id}).

update(Id, Doc) -> cast({update, Id, Doc}).

search(Query, Limit) -> call({search, Query, Limit}).
    
call(Request) ->
    binary_to_term(gen_server:call(?MODULE, term_to_binary(Request))).

cast(Request) ->
    gen_server:cast(?MODULE, term_to_binary(Request)).

% server side
init(Command) ->
    process_flag(trap_exit, true),
    ?LOG_NOTICE("port server to ~p booting", [Command]),
    Port = open_port({spawn, Command}, [{packet, 4}, binary]),
    {ok, #port_state{port = Port}}.

terminate(_Reason, #port_state{port = Port, map = Map}) ->
    case maps:size(Map) of
	0 -> ok;
	_ -> flush_port(Port, Map)
    end.

% each message has a 4 byte prefix:
% <<"P", 0, 0, 0>> for oneway message: Posted Write
% <<"R", Seq:24 (big ending 3 bytes)>> for message needing a reply: Request
% <<"C", Seq:24 (big ending 3 bytes)>> for reply to a previous request: Completion

handle_cast(Data, State = #port_state{port = Port}) ->
    port_command(Port, [<<"P", 0, 0, 0>> | Data]),
    {noreply, State}.

handle_call(Data, From, State = #port_state{port = Port, seq = Seq, map = Map}) ->
    case maps:is_key(Seq, Map) of
	true ->
	    error("sequence number still not released");
	false ->
	    port_command(Port, [<<"R", Seq:24>> | Data]),
	    {noreply, State#port_state{seq = next_seq(Seq), map = maps:put(Seq, From, Map)}}
    end.

handle_info({Port, {data, <<"C", Seq:24, Data/binary>>}},
	    State = #port_state{port = Port, map = Map}) ->
    {noreply, State#port_state{map = deliver_msg(Seq, Data, Map)}}.

% legal sequence number is 0 ~ 2^24-1
next_seq(16777215) -> 0;
next_seq(Seq) -> Seq + 1.

flush_port(Port, Map) ->
    receive
	{Port, {data, <<"C", Seq:24, Data/binary>>}} ->
	    NewMap = deliver_msg(Seq, Data, Map),
	    case maps:size(NewMap) of
		0 -> ok;
		_ -> flush_port(Port, NewMap)
	    end;
	_ -> flush_port(Port, Map)
    end.

deliver_msg(Seq, Data, Map) ->
    gen_server:reply(maps:get(Seq, Map), Data),
    maps:remove(Seq, Map).
	    
