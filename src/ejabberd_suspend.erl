%%%----------------------------------------------------------------------
%%% File    : ejabberd_socket.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Socket with zlib and TLS support library
%%% Created : 23 Aug 2006 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
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
-author('alexey@process-one.net').

%% API
-export([start/2,
         sleep/3,
         wake/3,
         flush/3,
	 reset_stream/1,
	 send/2,
	 send_xml/2,
	 change_shaper/2,
	 monitor/1,
	 get_sockmod/1,
	 close/1,
	 sockname/1, peername/1]).

-include("ejabberd.hrl").

-record(state, {sockmod, socket}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function:
%% Description:
%%--------------------------------------------------------------------

start(SockMod, Socket) ->
    SocketData = #state{sockmod = SockMod,
        socket = Socket}.

sleep(ejabberd_suspend, SocketData, Data) ->
    {already_asleep, ejabberd_suspend, SocketData};
sleep(SockMod, Socket, []) ->
    SocketData = start(SockMod, Socket),
    {ok, ejabberd_suspend, SocketData};
sleep(SockMod, Socket, Data) ->
    {notimplemented, SockMod, Socket}.

wake(ejabberd_suspend, SocketData, Data) ->
    #state{sockmod = SockMod, socket = Socket} = SocketData,
    flush_socket(SocketData),
    %% Take ourself out of the equation (note that we don't actually intercept
    %% any c2s traffic: only s2c traffic, so we just need to shut ourselves down
    %% and return the original sockmod and socket that we were passed.
    (SockMod):send(Socket, Data),
    {ok, SockMod, Socket};
wake(SockMod, Socket, _) ->
    {already_awake, SockMod, Socket}.

flush(ejabberd_suspend, SocketData, Data) ->
    #state{sockmod = SockMod, socket = Socket} = SocketData,
    flush_socket(SocketData),
    (SockMod):send(Socket, Data),
    {ok, ejabberd_suspend, SocketData}.

flush_socket(SocketData) ->
    ok.

%% sockmod=gen_tcp|tls|ejabberd_zlib
send(SocketData, Data) ->
    case catch (SocketData#state.sockmod):send(
	     SocketData#state.socket, Data) of
        ok -> ok;
	{error, timeout} ->
	    ?INFO_MSG("Timeout on ~p:send",[SocketData#state.sockmod]),
	    exit(normal);
        Error ->
	    ?DEBUG("Error in ~p:send: ~p",[SocketData#state.sockmod, Error]),
	    exit(normal)
    end.

%% Can only be called when in c2s StateData#state.xml_socket is true
%% This function is used for HTTP bind
%% sockmod=ejabberd_http_poll|ejabberd_http_bind or any custom module
send_xml(SocketData, Data) ->
    catch (SocketData#state.sockmod):send_xml(
	    SocketData#state.socket, Data).

%% Blindly proxy these calls down the chain.
reset_stream(SocketData) ->
    (SocketData#state.sockmod):reset_stream(SocketData#state.socket).

change_shaper(SocketData, Shaper) ->
    (SocketData#state.sockmod):change_shaper(SocketData#state.socket, Shaper).

monitor(SocketData) ->
    (SocketData#state.sockmod):monitor(SocketData#state.socket).

get_sockmod(SocketData) ->
    SocketData#state.sockmod.

close(SocketData) ->
    (SocketData#state.sockmod):close(SocketData#state.socket).

sockname(#state{sockmod = SockMod, socket = Socket}) ->
    case SockMod of
	gen_tcp ->
	    inet:sockname(Socket);
	_ ->
	    SockMod:sockname(Socket)
    end.

peername(#state{sockmod = SockMod, socket = Socket}) ->
    case SockMod of
	gen_tcp ->
	    inet:peername(Socket);
	_ ->
	    SockMod:peername(Socket)
    end.

%%====================================================================
%% Internal functions
%%====================================================================
