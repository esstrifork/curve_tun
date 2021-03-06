-module(curve_tun_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, groups/0,
	 init_per_group/2, end_per_group/2,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([send_recv/1]).

-define(TIMEOUT, 5000).

suite() ->
    [{timetrap, {seconds, 10}}].
    
%% Setup/Teardown
%% ----------------------------------------------------------------------
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    %% error_logger:tty(false), %% Disable the error loggers tty output for tests
    %%application:ensure_all_started(sasl),
    {ok, Apps} = application:ensure_all_started(curve_tun),
    PK = <<81,13,101,52,29,109,136,196,86,91,34,91,3,19,150,3,215,
    		43,210,9,242,146,119,188,153,245,78,232,94,113,37,47>>,
    [{apps, Apps}, {host, "127.0.0.1"}, {port, 1337}, {receiver_pk, PK}| Config].

end_per_suite(Config) ->
    Apps = proplists:get_value(apps, Config),
    [ok = application:stop(A) || A <- Apps],
    ok.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%% Tests
%% ----------------------------------------------------------------------
groups() ->
    [{basic, [shuffle, {repeat, 30}], [
        send_recv
    ]}].

all() ->
    [{group, basic}].

send_recv(Config) ->
    RPid = receiver(Config),
    SPid = sender(Config),

    error_logger:info_msg("sender=~p, receiver=~p, self=~p", [SPid, RPid, self()]),

    ok = join([RPid, SPid]),
    ok.

%% -------------------------------------
join([]) -> ok;
join([P | Next]) ->
    MRef = monitor(process, P),
    receive
        {'DOWN', MRef, _, _, Info} ->
            ct:fail({'DOWN', P, Info});
        {P, ok} ->
            demonitor(MRef, [flush]), join(Next);
        {P, {error, Err}} -> ct:fail(Err)

after ?TIMEOUT ->
       ct:fail(timeout)
   end.
   
sender(Config) ->
    Ctl = self(),
    proc_lib:spawn_link(fun() ->
        random:seed(erlang:now()),
        ct:sleep(10),
        sleep(),
        {ok, Sock} = curve_tun:connect(
            ?config(host, Config),
            ?config(port, Config),
            [{peer_public_key, ?config(receiver_pk, Config)}, {metadata, [{<<"a">>, <<"A">>}]}],
            3000),
        sleep(),
        {ok, [{<<"b">>, <<"B">>}]} = curve_tun:metadata(Sock),
        sleep(),
        ok = curve_tun:send(Sock, <<"1">>),
        sleep(),
        ok = curve_tun:send(Sock, <<"2">>),
        sleep(),

        curve_tun:setopts(Sock, [{active, once}]),
        receive
            {curve_tun, Sock, _Msg2} -> exit({unexpected_msg, _Msg2});
            {curve_tun_closed, Sock} -> exit(unexpected_close)
        after random:uniform(100) ->
            curve_tun:setopts(Sock, [{active, false}])
        end,
        sleep(),

        ok = curve_tun:send(Sock, <<"3">>),
        sleep(),
        ok = curve_tun:close(Sock),
        Ctl ! {self(), ok}
    end).
    
receiver(Config) ->
    Ctl = self(),
    proc_lib:spawn_link(fun() ->
        random:seed(erlang:now()),
        ok = curve_tun_simple_registry:register({127,0,0,1},<<81,13,101,52,29,109,136,196,86,91,34,91,3,19,150,3,215, 43,210,9,242,146,119,188,153,245,78,232,94,113,37,47>>),
        {ok, LSock} = curve_tun:listen(?config(port, Config), [{reuseaddr, true}, {metadata, [{<<"b">>, <<"B">>}]}]),
        sleep(),
        {ok, Sock} = curve_tun:accept(LSock),
        sleep(),
        {ok, [{<<"a">>, <<"A">>}]} = curve_tun:metadata(Sock),
        sleep(),
        {ok, <<"1">>} = curve_tun:recv(Sock),
        sleep(),
        {ok, <<"2">>} = curve_tun:recv(Sock),
        sleep(),
        curve_tun:setopts(Sock, [{active, once}]),
        receive
            {curve_tun, Sock, <<"3">>} -> ok
        end,
        sleep(),
        ok = curve_tun:close(Sock),
        Ctl ! {self(), ok}
    end).

sleep() ->
    ct:sleep(random:uniform(100)).
