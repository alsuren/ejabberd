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

-define(DEFAULT_PAUSE, 10 * 60 * 1000).

-define(GEN_FSM, p1_fsm).

-behaviour(?GEN_FSM).

%% API
-export([start/2,
         start_link/2,
         sleep/4,
         wake/3,
         flush/4]).

%% gen_fsm behaviour
-export([handle_sync_event/4,
         code_change/4,
         handle_event/3,
         handle_info/3,
         sleeping/2,
         init/1,
         terminate/3,
         print_state/1]).

%% sock_mod behaviour
-export([reset_stream/1,
         send/2,
         send_xml/2,
         change_shaper/2,
         monitor/1,
         get_sockmod/1,
         close/1,
         sockname/1,
         peername/1]).

-include("ejabberd.hrl").

-record(suspend_state, {
        sockmod,
        socket,
        c2sref,
        timer,
        pause,
        output = []}).

% This is what's passed back to ejabberd_c2s as the opaque "socket" datastructure
% There is redundancy here, but it simplifies the wrapping/unwrapping process.
-record(sockdata, {
        sockmod,
        socket,
        fsmref}).

%-define(DBGFSM, true).

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

sleep(ejabberd_suspend, SockData, _Pause, _Data) ->
    {already_asleep, ejabberd_suspend, SockData};
sleep(SockMod, Socket, PauseString, Data) ->
    ?INFO_MSG("Sleeping socket, and sending ~p.", [Data]),
    C2SRef = self(),
    Pause = pause_to_msec(PauseString),
    {ok, Pid} = start_link([C2SRef, Socket, SockMod, Pause, Data], []),
    {ok, ejabberd_suspend, #sockdata{sockmod = SockMod, socket = Socket, fsmref = Pid}}.

wake(ejabberd_suspend, SockData, Data) ->
    #sockdata{fsmref = FsmRef, sockmod = SockMod, socket = Socket} = SockData,
    ?INFO_MSG("Wakeing socket, and sending ~p.", [Data]),
    gen_fsm:sync_send_all_state_event(FsmRef, {wake_socket, Data}),
    %% Take ourself out of the equation (note that we don't actually intercept
    %% any c2s traffic: only s2c traffic, so we just need to shut ourselves down
    %% and return the original sockmod and socket that we were passed.
    {ok, SockMod, Socket};
wake(SockMod, Socket, _) ->
    {already_awake, SockMod, Socket}.

flush(ejabberd_suspend, SockData, PauseString, Data) ->
    #sockdata{fsmref = FsmRef} = SockData,
    ?INFO_MSG("Flushing socket, and sending ~p.", [Data]),
    Pause = pause_to_msec(PauseString),
    gen_fsm:sync_send_all_state_event(FsmRef, {flush_socket, Pause, Data}),
    {ok, ejabberd_suspend, SockData}.

send(#sockdata{fsmref = FsmRef}, Packet) ->
    ?INFO_MSG("Delaying sending of ~p.", [Packet]),
    gen_fsm:sync_send_all_state_event(FsmRef, {send, Packet}).

send_xml(#sockdata{fsmref = FsmRef}, Packet) ->
    ?INFO_MSG("Delaying sending of ~p.", [Packet]),
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


start(InitArgs, Opts) ->
    ?GEN_FSM:start(?MODULE, InitArgs, fsm_limit_opts(Opts) ++ ?FSMOPTS).

start_link(InitArgs, Opts) ->
    ?GEN_FSM:start_link(?MODULE, InitArgs,
                        fsm_limit_opts(Opts) ++ ?FSMOPTS).


%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------
sleeping(timeout, StateData) ->
    ?INFO_MSG("Stray timeout that I didn't ask for.", []),
    {next_state, sleeping, StateData};

sleeping(Msg, StateData) ->
    ?INFO_MSG("Stray ~p that I didn't ask for.", [Msg]),
    {next_state, sleeping, StateData}.

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
init([C2SRef, Socket, SockMod, Pause, Data]) ->
    (SockMod):send(Socket, Data),
    Timer = erlang:start_timer(Pause, self(), []),
    {ok, sleeping,
        #suspend_state{ c2sref = C2SRef, socket = Socket, sockmod = SockMod,
            timer = Timer}}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event({wake_socket, Data}, From, StateName, StateData0) ->
    StateData1 = StateData0#suspend_state{ c2sref = null },
    {reply, Reply, StateName, StateData2} = handle_sync_event({flush_socket, 1000, Data}, From, StateName, StateData1),
    {stop, normal, Reply, StateData2};

handle_sync_event({flush_socket, Pause, Data}, _From, StateName, StateData) ->
    cancel_timer(StateData#suspend_state.timer),
    #suspend_state{output = Output, sockmod = SockMod, socket = Socket} = StateData,
    [(SockMod):send(Socket, O) || O <- lists:reverse(Output)],
    (SockMod):send(Socket, Data),
    Timer = erlang:start_timer(Pause, self(), []),
    Reply = ok,
    {reply, Reply, StateName, StateData#suspend_state{timer = Timer, output = []}};

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
%% We reached the Pause timeout:
handle_info({timeout, Timer, _}, _StateName, #suspend_state{timer = Timer} = StateData) ->
    ?INFO_MSG("Session timeout. Closing suspended session to due to inactivity.", []),
    {stop, normal, StateData};

handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(_Reason, _StateName, StateData) ->
    case StateData#suspend_state.c2sref of
        null ->
            ok;
        C2SRef ->
            gen_fsm:send_event(C2SRef, closed)
    end,
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
%% If client asked for a pause, we apply the pause value
%% as inactivity timer:
set_inactivity_timer(Pause) ->
    erlang:start_timer(Pause, self(), []).

pause_to_msec([]) ->
    ?DEFAULT_PAUSE;
pause_to_msec(Pause) ->
    list_to_integer(Pause) * 1000.
