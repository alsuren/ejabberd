%%%----------------------------------------------------------------------
%%% File    : ejabberd_suspend.erl
%%% Author  : David Laban <alsuren@gmail.com>
%%% Purpose : Socket with the ability to queue/flush outbound traffic.
%%% Created : 1 Mar 2013 by David Laban <alsuren@gmail.com>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
%%%           Copyright (C) 2013        David Laban
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_suspend).
-author('alsuren@gmail.com').

-define(MAX_WAIT, 3600). % max num of secs to keep a request on hold
-define(MAX_INACTIVITY, 30000). % msecs to wait before terminating
                                % idle sessions

-define(GEN_FSM, p1_fsm).

-behaviour(?GEN_FSM).

%% API
-export([start/2,
         start_link/2,
         sleep/3,
         wake/3,
         flush/3,
         handle_sync_event/4,
         code_change/4,
         handle_event/3,
         handle_info/3,
         init/1,
         terminate/3,
         print_state/1,
	 reset_stream/1,
	 send/2,
	 send_xml/2,
	 change_shaper/2,
	 monitor/1,
	 get_sockmod/1,
	 close/1,
	 sockname/1, peername/1]).

-include("ejabberd.hrl").

-record(suspend_state, {
        sockmod,
        socket,
        socket_monitor,
        fsmref,
        timer,
        wait_timer,
        pause,
        max_inactivity,
        output = []}).

% This is what's passed back to ejabberd_c2s as the opaque "socket" datastructure
% There is redundancy here, but it simplifies the wrapping/unwrapping process,
% and reduces the amount of bullshit data that gets send to proceses' mailboxes.
-record(sockdata, {
        sockmod,
        socket,
        fsmref}).

-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function:
%% Description:
%%--------------------------------------------------------------------

sleep(ejabberd_suspend, SockData, _Data) ->
    {already_asleep, ejabberd_suspend, SockData};
sleep(SockMod, Socket, Data) ->
    {ok, Pid} = start_link([Socket, SockMod], []),
    (SockMod):send(Socket, Data),
    {ok, ejabberd_suspend, #sockdata{sockmod = SockMod, socket = Socket, fsmref = Pid}}.

wake(ejabberd_suspend, SockData, Data) ->
    #sockdata{fsmref = FsmRef, sockmod = SockMod, socket = Socket} = SockData,
    gen_fsm:sync_send_all_state_event(FsmRef, {flush_socket}),
    %% Take ourself out of the equation (note that we don't actually intercept
    %% any c2s traffic: only s2c traffic, so we just need to shut ourselves down
    %% and return the original sockmod and socket that we were passed.
    (SockMod):send(Socket, Data),
    {ok, SockMod, Socket};
wake(SockMod, Socket, _) ->
    {already_awake, SockMod, Socket}.

flush(ejabberd_suspend, SockData, Data) ->
    #sockdata{fsmref = FsmRef, sockmod = SockMod, socket = Socket} = SockData,
    gen_fsm:sync_send_all_state_event(FsmRef, {flush_socket}),
    (SockMod):send(Socket, Data),
    {ok, ejabberd_suspend, FsmRef}.

send(#sockdata{fsmref = FsmRef}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef, {send, Packet}).

send_xml(#sockdata{fsmref = FsmRef}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef, {send_xml, Packet}).

%% Blindly proxy these calls down the chain.
reset_stream(SocketData) ->
    (SocketData#sockdata.sockmod):reset_stream(SocketData#sockdata.socket).

change_shaper(SocketData, Shaper) ->
    (SocketData#sockdata.sockmod):change_shaper(SocketData#sockdata.socket, Shaper).

monitor(SocketData) ->
    (SocketData#sockdata.sockmod):monitor(SocketData#sockdata.socket).

get_sockmod(SocketData) ->
    SocketData#sockdata.sockmod.

close(SocketData) ->
    (SocketData#sockdata.sockmod):close(SocketData#sockdata.socket).

sockname(#sockdata{sockmod = SockMod, socket = Socket}) ->
    case SockMod of
	gen_tcp ->
	    inet:sockname(Socket);
	_ ->
	    SockMod:sockname(Socket)
    end.

peername(#sockdata{sockmod = SockMod, socket = Socket}) ->
    case SockMod of
	gen_tcp ->
	    inet:peername(Socket);
	_ ->
	    SockMod:peername(Socket)
    end.


start([Socket, SockMod], Opts) ->
    ?GEN_FSM:start(?MODULE, [Socket, SockMod], fsm_limit_opts(Opts) ++ ?FSMOPTS).

start_link([Socket, SockMod], Opts) ->
    ?GEN_FSM:start_link(?MODULE, [Socket, SockMod],
			fsm_limit_opts(Opts) ++ ?FSMOPTS).


%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
init([Socket, SockMod]) ->
    Timer = erlang:start_timer(?MAX_INACTIVITY, self(), []),
    SocketMonitor = SockMod:monitor(Socket),
    {ok, sleeping,
        #suspend_state{ socket = Socket, sockmod = SockMod,
            socket_monitor = SocketMonitor, timer = Timer},
        ?MAX_INACTIVITY}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event({flush_socket}, _From, StateName, StateData) ->
    #suspend_state{output = Output, sockmod = SockMod, socket = Socket} = StateData,
    [(SockMod):send(Socket, O) || O <- Output],
    Reply = ok,
    {reply, Reply, StateName, StateData#suspend_state{output = []}};

handle_sync_event({send_xml, Packet}, _From, StateName, StateData) ->
    Output = [Packet | StateData#suspend_state.output],
    Reply = ok,
    {reply, Reply, StateName, StateData#suspend_state{output = Output}};

handle_sync_event({send, Packet}, _From, StateName, StateData) ->
    Output = [Packet | StateData#suspend_state.output],
    Reply = ok,
    {reply, Reply, StateName, StateData#suspend_state{output = Output}}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
%% We reached the max_inactivity timeout:
handle_info({timeout, Timer, _}, _StateName, #suspend_state{timer = Timer} = StateData) ->
    ?INFO_MSG("Session timeout. Closing suspended session to ~p due to inactivity.", [peername(StateData)]),
    {stop, normal, StateData};

handle_info({timeout, WaitTimer, _}, StateName,
	    #suspend_state{wait_timer = WaitTimer} = StateData) ->
    if true ->
	    cancel_timer(StateData#suspend_state.timer),
	    Timer = set_inactivity_timer(StateData#suspend_state.pause,
					 StateData#suspend_state.max_inactivity),
	    %%%gen_fsm:reply(StateData#suspend_state.http_receiver, {ok, empty}),
	    %%%Rid = StateData#suspend_state.rid,
	    %%%ReqList = [#hbr{rid = Rid,
			    %%%key = StateData#suspend_state.key,
			    %%%out = []
			   %%%} |
		       %%%[El || El <- StateData#suspend_state.req_list,
			      %%%El#hbr.rid /= Rid ]
		      %%%],
	    {next_state, StateName,
	     StateData#suspend_state{%%%http_receiver = undefined,
			     %%%req_list = ReqList,
			     wait_timer = undefined,
			     timer = Timer}}
    end;

handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(_Reason, _StateName, _StateData) ->
    ok.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

print_state(StateData) ->
    StateData.

%%====================================================================
%% Internal functions
%%====================================================================

fsm_limit_opts(Opts) ->
    case lists:keysearch(max_fsm_queue, 1, Opts) of
	{value, {_, N}} when is_integer(N) ->
	    [{max_queue, N}];
	_ ->
	    case ejabberd_config:get_local_option(max_fsm_queue) of
		N when is_integer(N) ->
		    [{max_queue, N}];
		_ ->
		    []
	    end
    end.

%% Cancel timer and empty message queue.
cancel_timer(undefined) ->
    ok;
cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    receive
	{timeout, Timer, _} ->
	    ok
    after 0 ->
	    ok
    end.
%%
%% If client asked for a pause (pause > 0), we apply the pause value
%% as inactivity timer:
set_inactivity_timer(Pause, _MaxInactivity) when Pause > 0 ->
    erlang:start_timer(Pause*1000, self(), []);
%% Otherwise, we apply the max_inactivity value as inactivity timer:
set_inactivity_timer(_Pause, MaxInactivity) ->
    erlang:start_timer(MaxInactivity, self(), []).

