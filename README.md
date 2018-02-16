# Erlang Core MIDI
Erlang wrapper library for Core MIDI.

```erlang
test() ->
    application:ensure_all_started(coremidi),

    {ok, Devices} = coremidi:list_devices(),

    {ok, Con} = coremidi:start_link([{device, "My MIDI Device"}, {entity, {0, 0}}]),


    % blocking recv
    Msg1 = coremidi:recv(Con),

    coremidi:send(Con, Msg1),


    % non blocking recv
    coremidi:arecv(Con),

    receive
        {Con, Msg2} ->
            coremidi:send(Con, Msg2)

    end,


    % non blocking sub
    coremidi:sub(Con),

    lists:foreach(fun(_) ->
            receive
                {Con, Msg} ->
                    coremidi:send(Con, Msg)

            end
        end,
        lists:seq(0, 9)),

    coremidi:unsub(Con),

    coremidi:stop(Con).
```
