-module(curve_tun_connection).
-behaviour(gen_fsm).

-export([connect/3, accept/1, listen/2, send/2, close/1, recv/1, controlling_process/2]).

%% Private callbacks
-export([start_fsm/0, start_link/1]).

%% FSM callbacks
-export([init/1, code_change/4, terminate/3, handle_info/3, handle_event/3, handle_sync_event/4]).

-export([
	closed/2, closed/3,
	connected/2, connected/3,
	initiating/2, initiating/3,
	ready/2, ready/3
]).

-record(curve_tun_lsock, { lsock :: port () }).

-record(curve_tun_socket, { pid :: pid() }).

connect(Address, Port, Options) ->
    {ok, Pid} = start_fsm(),
    case gen_fsm:sync_send_event(Pid, {connect, Address, Port, Options}) of
        ok ->
            {ok, #curve_tun_socket { pid = Pid }};
        {error, Reason} ->
            {error, Reason}
    end.

send(#curve_tun_socket { pid = Pid }, Msg) ->
    gen_fsm:sync_send_event(Pid, {send, Msg}).

recv(#curve_tun_socket { pid = Pid }) ->
    gen_fsm:sync_send_event(Pid, recv).

close(#curve_tun_socket { pid = Pid }) ->
    gen_fsm:sync_send_event(Pid, close).

listen(Port, Opts) ->
    Options = [binary, {packet, 2}, {active, false} | Opts],
    case gen_tcp:listen(Port, Options) of
        {ok, LSock} -> {ok, #curve_tun_lsock { lsock = LSock }};
        {error, Reason} -> {error, Reason}
    end.

accept(#curve_tun_lsock { lsock = LSock}) ->
    {ok, Pid} = start_fsm(),
    case gen_fsm:sync_send_event(Pid, {accept, LSock}) of
       ok ->
           {ok, #curve_tun_socket { pid = Pid }};
       {error, Reason} ->
           {error, Reason}
   end.

controlling_process(#curve_tun_socket { pid = Pid }, Controller) ->
    gen_fsm:sync_send_all_state_event(Pid, {controlling_process, Controller}).

%% @private
start_fsm() ->
    Controller = self(),
    {ok, Pid} = curve_tun_connection_sup:start_child([Controller]),
    {ok, Pid}.

%% @private
start_link(Controller) ->
    gen_fsm:start_link(?MODULE, [Controller], []).
    
%% @private
init([Controller]) ->
    Ref = erlang:monitor(process, Controller),
    State = #{
        vault => curve_tun_vault_dummy,
        registry => curve_tun_simple_registry,
        controller => {Controller, Ref}
    },
    {ok, ready, State}.


%% @private
ready({accept, LSock}, From, State) ->
    case gen_tcp:accept(LSock) of
        {error, Reason} ->
            {stop, normal, {error, Reason}, ready, State};
        {ok, Socket} ->
            InitState = State#{ socket => Socket },
            ok = inet:setopts(Socket, [{active, once}]),
            {ok, EC} = recv_hello(InitState),
            case send_cookie(EC, InitState) of
                ok ->
                    ok = inet:setopts(Socket, [{active, once}]),
                    {next_state, accepting, InitState#{ from => From }};
                {error, Reason} ->
                    {stop, normal, {error, Reason}, State}
           end
    end;
ready({connect, Address, Port, Options}, From, State) ->
    TcpOpts = lists:keydelete(key, 1, [{packet, 2}, binary, {active, false} | Options]),
    S = proplists:get_value(key, Options),
    case gen_tcp:connect(Address, Port, TcpOpts) of
        {error, Reason} ->
            {stop, normal, {error, Reason}, State};
        {ok, Socket} ->
            #{ public := EC, secret := ECs } = enacl:box_keypair(),
            InitState = #{ peer_lt_public_key => S, public_key => EC, secret_key => ECs, socket => Socket },
            case send_hello(InitState) of
                ok ->
                    ok = inet:setopts(Socket, [{active, once}]),
                    {next_state, initiating, InitState#{ from => From }};
                {error, Reason} ->
                    {stop, normal, {error, Reason}, State}
            end
    end.
    
ready(_Msg, ready) ->
    {stop, argh, ready}.

initiating(_Msg, _From, _State) ->
    {stop, argh, ready}.

initiating(_Msg, _) ->
    {stop, argh, ready}.

closed(_Msg, _State) ->
    {stop, argh, closed}.
    
closed({send, _}, _From, State) ->
    {reply, {error, closed}, State}.

connected(_M, _) ->
    {stop, argh, connected}.

connected(close, _From, #{ socket := Sock } = State) ->
    ok = gen_tcp:close(Sock),
    {stop, normal, ok, connected, maps:remove(socket, State)};
connected(recv, From, #{ socket := Sock, recv_queue := Q } = State) ->
    ok = handle_socket(Sock, next),
    {next_state, connected, State#{ recv_queue := queue:in(From, Q) }};
connected({send, M}, _From, State) ->
    {Reply, NState} = send_msg(M, State),
    {reply, Reply, connected, NState}.

handle_sync_event({controlling_process, Controller}, {PrevController, _Tag}, Statename,
        #{ controller := {PrevController, MRef} } = State) ->
    erlang:demonitor(MRef, [flush]),
    NewRef = erlang:monitor(process, Controller),
    {reply, ok, Statename, State# { controller := {Controller, NewRef}}};
handle_sync_event({controlling_process, _Controller}, _From, Statename, State) ->
    {reply, {error, not_owner}, Statename, State};
handle_sync_event(Event, _From, Statename, State) ->
    error_logger:info_msg("Unknown sync_event ~p in state ~p", [Event, Statename]),
    {next_state, Statename, State}.

handle_event(Event, Statename, State) ->
    error_logger:info_msg("Unknown event ~p in state ~p", [Event, Statename]),
    {next_state, Statename, State}.

handle_info({'DOWN', _Ref, process, Pid, _Info}, _Statename, #{ controller := Pid, socket := Socket } = State) ->
    ok = gen_tcp:close(Socket),
    {stop, tcp_closed, maps:remove(socket, State)};
handle_info({tcp, Sock, Data}, Statename, #{ socket := Sock } = State) ->
    case handle_packet(d_packet(Data), Statename, State) of
        {Next, NewStateName, NewState} ->
            ok = handle_socket(Sock, Next),
            {next_state, NewStateName, NewState};
        {error, _Reason} = Err ->
            {stop, Statename, reply(Err, State)}
    end;
handle_info({tcp_closed, S}, Statename, # { socket := S } = State) ->
    handle_tcp_closed(Statename, State);
handle_info(Info, Statename, State) ->
    error_logger:info_msg("Unknown info msg ~p in state ~p", [Info, Statename]),
    {next_state, Statename, State}.

terminate(_Reason, _Statename, _State) ->
    ok.

code_change(_OldVsn, Statename, State, _Aux) ->
    {ok, Statename, State}.

%% INTERNAL HANDLERS

unpack_cookie(<<Nonce:16/binary, Cookie/binary>>) ->
    CNonce = lt_nonce(minute_k, Nonce),
    Keys = curve_tun_cookie:recent_keys(),
    unpack_cookie_(Keys, CNonce, Cookie).
    
unpack_cookie_([], _, _) -> {error, ecookie};
unpack_cookie_([K | Ks], CNonce, Cookie) ->
    case enacl:secretbox_open(Cookie, CNonce, K) of
        {ok, <<EC:32/binary, ESs:32/binary>>} -> {ok, EC, ESs};
        {error, failed_verification} ->
            unpack_cookie_(Ks, CNonce, Cookie)
    end.

reply(M, #{ from := From } = State) ->
    gen_fsm:reply(From, M),
    maps:remove(from, State).
    

handle_socket(Sock, next) -> inet:setopts(Sock, [{active, once}]);
handle_socket(_Sock, hold) -> ok.

handle_recv_queue(#{ recv_queue := Q, buf := Buf } = State) ->
    case {queue:out(Q), Buf} of
        {{{value, _Receiver}, _Q2}, undefined} ->
            {next, connected, State};
        {{{value, Receiver}, Q2}, Msg} ->
            gen_fsm:reply(Receiver, Msg),
            handle_recv_queue(State#{ recv_queue := Q2, buf := undefined });
        {{empty, _Q2}, _} ->
            {hold, connected, State}
   end.

handle_msg(N, Box, #{ peer_public_key := P, secret_key := Ks, buf := undefined, side := Side } = State) ->
    Nonce = case Side of
                client -> st_nonce(msg, server, N);
                server -> st_nonce(msg, client, N)
            end,
    {ok, Msg} = enacl:box_open(Box, Nonce, P, Ks),
    handle_recv_queue(State#{ buf := Msg }).

handle_vouch(K, N, Box, #{ socket := Sock, vault := Vault, registry := Registry } = State) ->
    case unpack_cookie(K) of
        {ok, EC, ESs} ->
            Nonce = st_nonce(initiate, client, N),
            {ok, <<C:32/binary, NonceLT:16/binary, Vouch/binary>>} = enacl:box_open(Box, Nonce, EC, ESs),
            true = Registry:verify(Sock, C),
            VNonce = lt_nonce(client, NonceLT),
            {ok, <<EC:32/binary>>} = Vault:box_open(Vouch, VNonce, C),
            %% Everything seems to be in order, go to connected state
            NState = State#{ recv_queue => queue:new(), buf => undefined, 
                             secret_key => ESs, peer_public_key => EC, c => 0, side => server },  
            {hold, connected, reply(ok, NState)};
        {error, Reason} ->
            {error, Reason}
    end.

handle_cookie(N, Box, #{ secret_key := ECs, peer_lt_public_key := S } = State) ->
    Nonce = lt_nonce(server, N),
    {ok, <<ES:32/binary, K/binary>>} = enacl:box_open(Box, Nonce, S, ECs),
    {ok, NState} = send_vouch(K, State#{ peer_public_key => ES }),
    {hold, connected, reply(ok, NState#{ recv_queue => queue:new(), buf => undefined, side => client })}.

handle_packet(<<109,27,57,203,246,90,17,180, N:64/integer, Box/binary>>, connected, State) ->
    handle_msg(N, Box, State);
handle_packet(<<108,9,175,178,138,169,250,253, K:96/binary, N:64/integer, Box/binary>>, accepting, State) ->
    handle_vouch(K, N, Box, State);
handle_packet(<<28,69,220,185,65,192,227,246,  N:16/binary, Box/binary>>, initiating, State) ->
    handle_cookie(N, Box, State).

handle_tcp_closed(_Statename, State) ->
    {next_state, closed, maps:remove(socket, State)}.

%% NONCE generation
%%
%% There are two types of nonces: short-term (st) and long-term (lt)

st_nonce(hello, client, N) -> <<"CurveCP-client-H", N:64/integer>>;
st_nonce(initiate, client, N) -> <<"CurveCP-client-I", N:64/integer>>;
st_nonce(msg, client, N) -> <<"CurveCP-client-M", N:64/integer>>;
st_nonce(hello, server, N) -> <<"CurveCP-server-H", N:64/integer>>;
st_nonce(initiate, server, N) -> <<"CurveCP-server-I", N:64/integer>>;
st_nonce(msg, server, N) -> <<"CurveCP-server-M", N:64/integer>>.

lt_nonce(minute_k, N) -> <<"minute-k", N/binary>>;
lt_nonce(client, N) -> <<"CurveCPV", N/binary>>;
lt_nonce(server, N) -> <<"CurveCPK", N/binary>>.

%% RECEIVING expected messages
recv_hello(#{ socket := Socket, vault := Vault}) ->
    receive
        {tcp, Socket, Data} ->
            case d_packet(Data) of
                {hello, EC, N, Box} ->
                    STNonce = st_nonce(hello, client, N),
                    {ok, <<0:512/integer>>} = Vault:box_open(Box, STNonce, EC),
                    {ok, EC};
                Otherwise ->
                    error_logger:info_report([received, Otherwise]),
                    {error, ehello}
            end
   after 5000 ->
       {error, timeout}
   end.

%% SENDING messages over the wire
send_hello(#{ peer_lt_public_key := S, public_key := EC, secret_key := ECs, socket := Socket }) ->
    N = 0,
    gen_tcp:send(Socket, e_hello(S, EC, ECs, N)).

send_cookie(EC, #{ socket := Socket, vault := Vault}) ->
    %% Once ES is in the hands of the client, the server doesn't need it anymore
    #{ public := ES, secret := ESs } = enacl:box_keypair(),
    gen_tcp:send(Socket, e_cookie(EC, ES, ESs, Vault)).

send_vouch(Kookie, #{ socket := Socket,
	public_key := EC,
	secret_key := ECs,
	peer_lt_public_key := S,
	peer_public_key := ES,
	vault := Vault } = State) ->
    case gen_tcp:send(Socket, e_vouch(Kookie, EC, S, Vault, 1, ES, ECs)) of
        ok -> {ok, State#{ c => 2 }};
        {error, Reason} -> {error, Reason}
    end.
   
send_msg(M, #{ socket := Socket, secret_key := Ks, peer_public_key := P, c := NonceCount, side := Side } = State) ->
    case gen_tcp:send(Socket, e_msg(M, Side, NonceCount, P, Ks)) of
         ok -> {ok, State#{ c := NonceCount + 1}};
         {error, Reason} -> {error, Reason}
    end.

%% COMMAND GENERATION
%% 
%% The c_* functions produce messages for the wire. They are kept here
%% for easy perusal. Note that while the arguments are terse, they do have
%% meaning since they reflect the meaning of the protocol specification. For
%% instance, the argument ECs means (E)phermeral (C)lient (s)ecret key.
e_hello(S, EC, ECs, N) ->
    Nonce = st_nonce(hello, client, N),
    Box = enacl:box(binary:copy(<<0>>, 64), Nonce, S, ECs),
    <<108,9,175,178,138,169,250,252, EC:32/binary, N:64/integer, Box/binary>>.

e_cookie(EC, ES, ESs, Vault) ->
    Ts = curve_tun_cookie:current_key(),
    SafeNonce = Vault:safe_nonce(),
    CookieNonce = lt_nonce(minute_k, SafeNonce),

    KBox = enacl:secretbox(<<EC:32/binary, ESs:32/binary>>, CookieNonce, Ts),
    K = <<SafeNonce:16/binary, KBox/binary>>,
    BoxNonce = lt_nonce(server, SafeNonce),
    Box = Vault:box(<<ES:32/binary, K/binary>>, BoxNonce, EC),
    <<28,69,220,185,65,192,227,246, SafeNonce:16/binary, Box/binary>>.

e_vouch(Kookie, VMsg, S, Vault, N, ES, ECs) when byte_size(Kookie) == 96 ->
    NonceBase = Vault:safe_nonce(),

    %% Produce the box for the vouch
    VouchNonce = lt_nonce(client, NonceBase),
    VouchBox = Vault:box(VMsg, VouchNonce, S),
    C = Vault:public_key(),
    
    STNonce = st_nonce(initiate, client, N),
    Box = enacl:box(<<C:32/binary, NonceBase/binary, VouchBox/binary>>, STNonce, ES, ECs),
    <<108,9,175,178,138,169,250,253, Kookie/binary, N:64/integer, Box/binary>>.
    
e_msg(M, Side, NonceCount, PK, SK) ->
    Nonce = st_nonce(msg, Side, NonceCount),
    Box = enacl:box(M, Nonce, PK, SK),
    <<109,27,57,203,246,90,17,180, NonceCount:64/integer, Box/binary>>.

%% PACKET DECODING
%%
%% To make it easy to understand what is going on, keep the packet decoder
%% close the to encoding of messages. The above layers then handle the
%% semantics of receiving and sending commands/packets over the wire
d_packet(<<109,27,57,203,246,90,17,180, N:64/integer, Box/binary>>) ->
    {msg, N, Box};
d_packet(<<108,9,175,178,138,169,250,253, K:96/binary, N:64/integer, Box/binary>>) ->
    {vouch, K, N, Box};
d_packet(<<28,69,220,185,65,192,227,246,  N:16/binary, Box/binary>>) ->
    {cookie, N, Box};
d_packet(<<108,9,175,178,138,169,250,252, EC:32/binary, N:64/integer, Box/binary>>) ->
    {hello, EC, N, Box};
d_packet(_) ->
    unknown.
    
