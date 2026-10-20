#!/usr/bin/env escript
%% A UCI engine that cannot play chess and always answers the same.
%% Written in Erlang so that `escript` runs it on any machine the tests run
%% on, without compiling anything first.
%%
%% Usage: escript fake_uci.escript MODE [ARG]
%%
%%   normal          four lines, best e2e4 (+30), then d2d4, g1f3, c2c4;
%%                   a `searchmoves M` search answers M at -120
%%   mate            line 1 is mate in 2, line 2 mated in 3
%%   crash           dies on the first `go`
%%   crash_once F    dies on the first `go` unless file F exists (and makes it)
%%   hang            never answers a `go`
%%   critical        says `info string CRITICAL ERROR ...` and dies on `go`
-mode(compile).

main(Args) ->
    {Mode, Arg} = case Args of
        [M, A | _] -> {M, A};
        [M] -> {M, none};
        [] -> {"normal", none}
    end,
    loop(Mode, Arg).

loop(Mode, Arg) ->
    case io:get_line("") of
        eof -> halt(0);
        {error, _} -> halt(0);
        Line ->
            Cmd = string:trim(Line),
            handle(Cmd, Mode, Arg),
            loop(Mode, Arg)
    end.

say(Text) -> io:put_chars([Text, "\n"]).

handle("uci", _Mode, _Arg) ->
    say("id name FakeFish 1"),
    say("id author nobody in particular"),
    say("option name Hash type spin default 16 min 1 max 1024"),
    say("option name MultiPV type spin default 1 min 1 max 256"),
    say("uciok");
handle("isready", _Mode, _Arg) -> say("readyok");
handle("quit", _Mode, _Arg) -> halt(0);
handle("go" ++ Rest, Mode, Arg) -> go(string:split(string:trim(Rest), " ", all), Mode, Arg);
handle(_Other, _Mode, _Arg) -> ok.

go(Words, Mode, Arg) ->
    case Mode of
        "crash" -> halt(3);
        "hang" -> timer:sleep(infinity);
        "critical" ->
            say("info string CRITICAL ERROR: invalid position"),
            halt(1);
        "crash_once" ->
            case filelib:is_file(Arg) of
                true -> answer(Words, "normal");
                false ->
                    ok = file:write_file(Arg, <<"crashed">>),
                    halt(3)
            end;
        _ -> answer(Words, Mode)
    end.

answer(Words, Mode) ->
    case lists:dropwhile(fun(W) -> W =/= "searchmoves" end, Words) of
        ["searchmoves", Move | _] ->
            say("info depth 1 seldepth 2 multipv 1 score cp -90 nodes 10 nps 1000 pv " ++ Move),
            say("info depth 9 seldepth 12 multipv 1 score cp -120 nodes 900 nps 9000 pv " ++ Move ++ " e7e5"),
            say("bestmove " ++ Move);
        _ ->
            say("info string fake search"),
            say("info depth 1 seldepth 1 multipv 1 score cp 5 nodes 20 nps 2000 pv a2a3"),
            say("info depth 2 currmove e2e4 currmovenumber 1"),
            lines(Mode),
            say("bestmove e2e4 ponder e7e5")
    end.

lines("mate") ->
    say("info depth 9 seldepth 4 multipv 1 score mate 2 nodes 900 nps 9000 pv d1d8 g8h7 d8h8"),
    say("info depth 9 seldepth 6 multipv 2 score mate -3 nodes 900 nps 9000 pv a1a2 b2b1q");
lines(_normal) ->
    say("info depth 9 seldepth 12 multipv 1 score cp 30 nodes 900 nps 9000 pv e2e4 e7e5 g1f3"),
    say("info depth 9 seldepth 12 multipv 2 score cp 20 upperbound nodes 900 nps 9000 pv d2d4 d7d5"),
    say("info depth 9 seldepth 12 multipv 3 score cp 10 nodes 900 nps 9000 pv g1f3 g8f6"),
    say("info depth 9 seldepth 12 multipv 4 score cp -5 nodes 900 nps 9000 pv c2c4 e7e5").
