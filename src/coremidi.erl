-module(coremidi).
-behaviour(gen_server).

-export([list_devices/0,
         list_devices/1]).

-export([start_link/1,
         start/1,
         stop/1,
         send/2,
         recv/1,
         recv/2,
         arecv/1,
         sub/1,
         unsub/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-record(state, {port,
                monitor,
                restart,
                executable,
                device,
                entity,
                data,
                subscribers}).

-include_lib("coremidi/include/coremidi.hrl").


-define(ECM_DEVICE, "ecm-device").
-define(ECM_VIRTUALDEVICE, "ecm-virtualdevice").
-define(ECM_LIST_DEVICES, "ecm-list-devices").


list_devices() ->
    list_devices(true).

list_devices(true) ->
    case ets:info(?MODULE) of
        undefined -> list_devices(false);
        _ ->
            [{devices, Result}] = ets:lookup(?MODULE, devices),

            {ok, Result}

    end;

list_devices(_) ->
    case ets:info(?MODULE) of
        undefined -> ets:new(?MODULE, [named_table, bag, {keypos, 1}]);
        _ -> ok
    end,

    {ok, CWD} = file:get_cwd(),
    PrivDir = filename:join([CWD, code:priv_dir(coremidi)]),
    Cmd = os:find_executable(filename:join([PrivDir, ?ECM_LIST_DEVICES])),
    Port = open_port({spawn_executable, Cmd}, [exit_status, binary]),

    case list_devices_run_loop(Port, <<>>) of
        {ok, RawData} ->
            try
                Data = binary_to_list(RawData),
                {ok, Tokens, _} = erl_scan:string(Data),
                {ok, [Expr]} = erl_parse:parse_exprs(Tokens),
                {value, Devices, _} = erl_eval:expr(Expr, []),

                ets:insert(?MODULE, {devices, Devices}),

                {ok, Devices}

            catch
                _:Reason -> {error, {baddata, RawData, Reason}}

            end;

        Error ->
            Error

    end.


list_devices_run_loop(Port, Data) ->
    receive
        {Port, {data, NewData}} ->
            list_devices_run_loop(Port, <<Data/binary, NewData/binary>>);

        {Port, {exit_status, 0}} ->
            {ok, Data};

        {Port, {exit_status, Status}} ->
            {error, {exit_status, Status}}

    end.


start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).


start(Args) ->
    gen_server:start(?MODULE, Args, []).


stop(Con) ->
    gen_server:stop(Con).


send(Con, Message) ->
    gen_server:cast(Con, {send, Message}).


recv(Con) ->
    recv(Con, infinity).


recv(Con, Timeout) ->
    gen_server:call(Con, recv, Timeout).


arecv(Con) ->
    gen_server:cast(Con, {recv, self()}).


sub(Con) ->
    gen_server:cast(Con, {sub, self()}).


unsub(Con) ->
    gen_server:cast(Con, {unsub, self()}).


init(Args) ->
    lager:debug("initialized with ~p", [Args]),

    {device, Device} = lists:keyfind(device, 1, Args),
    {entity, Entity} = lists:keyfind(entity, 1, Args),

    {ok, CWD} = file:get_cwd(),
    PrivDir = filename:join([CWD, code:priv_dir(coremidi)]),

    lager:debug("priv dir is ~p", [PrivDir]),

    Executable = case lists:keyfind(mode, 1, Args) of
            {mode, virtual} ->
                os:find_executable(filename:join([PrivDir, ?ECM_VIRTUALDEVICE]));
            _ ->
                os:find_executable(filename:join([PrivDir, ?ECM_DEVICE]))
        end,

    lager:debug("using executable ~p", [Executable]),

    Restart = proplists:get_value(restart, Args, false),

    Subs = case lists:keyfind(callback, 1, Args) of
            {callback, Callback} -> [Callback];
            _ -> []
        end,

    {ok, State} = start_port(#state{restart = Restart,
                                    executable = Executable,
                                    device = Device,
                                    entity = Entity,
                                    data = <<>>,
                                    subscribers = Subs}),

    {ok, State, ?ECM_DEFAULT_TIMEOUT}.


handle_call(recv, From, State) ->
    Subs = lists:usort([{sync, From} | State#state.subscribers]),

    {noreply, State#state{subscribers = Subs}, ?ECM_DEFAULT_TIMEOUT};

handle_call(Message, _From, State) ->
    {reply, {error, {badmessage, Message}}, State, ?ECM_DEFAULT_TIMEOUT}.


handle_cast({send, Message}, State) ->
    case send_message(Message, State) of
        {ok, NewState} ->
            {noreply, NewState, ?ECM_DEFAULT_TIMEOUT};

        _ ->
            {noreply, State, ?ECM_DEFAULT_TIMEOUT}

    end;

handle_cast({recv, From}, State) ->
    Subs = lists:usort([{async, From} | State#state.subscribers]),

    {noreply, State#state{subscribers = Subs}, ?ECM_DEFAULT_TIMEOUT};

handle_cast({sub, From}, State) ->
    Subs = lists:usort([From | State#state.subscribers]),

    {noreply, State#state{subscribers = Subs}, ?ECM_DEFAULT_TIMEOUT};

handle_cast({unsub, From}, State) ->
    Subs = lists:usort(lists:delete(From, State#state.subscribers)),

    {noreply, State#state{subscribers = Subs}, ?ECM_DEFAULT_TIMEOUT};

handle_cast(_Message, State) ->
    {noreply, State, ?ECM_DEFAULT_TIMEOUT}.


handle_info({'DOWN', _Monitor, port, _Port, Reason}, State) ->
    try_restart_port(Reason, State);

handle_info({Port, {data, Data}}, State) when is_port(Port) ->
    AllData = <<(State#state.data)/binary, Data/binary>>,

    case decode(AllData) of
        {ok, {Message, NewData}} ->
            recv_message(Message, State#state{data = NewData});

        _ ->
            {noreply, State#state{data = AllData}, ?ECM_DEFAULT_TIMEOUT}

    end;

handle_info(timeout, State) ->
    case erlang:port_info(State#state.port) of
        undefined ->
            try_restart_port(port_closed, State);

        _ ->
            {noreply, State, ?ECM_DEFAULT_TIMEOUT}

    end;

handle_info(_Message, State) ->
    {noreply, State, ?ECM_DEFAULT_TIMEOUT}.


terminate(_Reason, State) ->
    demonitor(State#state.monitor),
    
    case erlang:port_info(State#state.port) of
        undefined -> ok;
        _ -> port_close(State#state.port)
    end.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


start_port(State) ->
    Device = State#state.device,
    Entity = State#state.entity,
    Executable = State#state.executable,

    PortArgs = [Device, lists:flatten(io_lib:format("~p", [Entity]))],
    Port = open_port({spawn_executable, Executable},
                     [{packet, 2}, binary, {args, PortArgs}]),

    Monitor = monitor(port, Port),

    {ok, State#state{port = Port,
                     monitor = Monitor}}.


try_restart_port(Reason, State) ->
    case State#state.restart of
        true ->
            demonitor(State#state.monitor),

            case start_port(State) of
                {ok, NewState} ->
                    {noreply, NewState, ?ECM_DEFAULT_TIMEOUT};

                _ ->
                    {stop, Reason, State}

            end;

        _ ->
            {stop, Reason, State}

    end.


send_message(Message, State) ->
    case encode(Message) of
        {ok, EncodedMessage} ->
            port_command(State#state.port, EncodedMessage),

            {ok, State};

        Error ->
            Error

    end.


recv_message(Message, State) ->
    Subs = lists:filter(fun(Callback) ->
            case Callback of
                {sync, Pid} ->
                    gen_server:reply(Pid, Message),
                    false;

                {async, Pid} when is_pid(Pid) ->
                    Pid ! {self(), {message, Message}},
                    false;

                Pid when is_pid(Pid) ->
                    Pid ! {self(), {message, Message}},
                    true;

                Fun when is_function(Fun) ->
                    apply(Fun, [Message]),
                    true;

                {Fun, Args} ->
                    apply(Fun, [Message | Args]),
                    true;

                {Module, Fun, Args} ->
                    apply(Module, Fun, [Message | Args]),
                    true;

                _ ->
                    false

                end
            end,
            State#state.subscribers),

    {noreply, State#state{subscribers = Subs}, ?ECM_DEFAULT_TIMEOUT}.


encode({note_off, C, N, V}) ->
    {ok, <<16#8:4, C:4, 0:1, N:7, 0:1, V:7>>};

encode({note_on, C, N, V}) ->
    {ok, <<16#9:4, C:4, 0:1, N:7, 0:1, V:7>>};

encode({aftertouch, C, N, V}) ->
    {ok, <<16#a:4, C:4, 0:1, N:7, 0:1, V:7>>};

encode({control, C, N, V}) ->
    {ok, <<16#b:4, C:4, 0:1, N:7, 0:1, V:7>>};

encode({program, C, P}) ->
    {ok, <<16#c:4, C:4, 0:1, P:7>>};

encode({aftertouch, C, V}) ->
    {ok, <<16#d:4, C:4, 0:1, V:7>>};

encode({pitch, C, P}) ->
    {ok, <<16#e:4, C:4, 0:1, (P band 16#7f):7, 0:1, (P bsr 7):7>>};

encode(_) ->
    {error, baddata}.


decode(Data) when is_list(Data) ->
    decode(list_to_binary(Data));

decode(Data) when not is_binary(Data) ->
    {error, baddata};

decode(Data) ->
    case Data of
        <<16#8:4, C:4, 0:1, N:7, 0:1, V:7, T/binary>> ->
            {ok, {{note_off, C, N, V}, T}};

        <<16#9:4, C:4, 0:1, N:7, 0:1, V:7, T/binary>> ->
            {ok, {{note_on, C, N, V}, T}};

        <<16#a:4, C:4, 0:1, N:7, 0:1, V:7, T/binary>> ->
            {ok, {{aftertouch, C, N, V}, T}};

        <<16#b:4, C:4, 0:1, N:7, 0:1, V:7, T/binary>> ->
            {ok, {{control, C, N, V}, T}};

        <<16#c:4, C:4, 0:1, P:7, T/binary>> ->
            {ok, {{program, C, P}, T}};

        <<16#d:4, C:4, 0:1, V:7, T/binary>> ->
            {ok, {{aftertouch, C, V}, T}};

        <<16#e:4, C:4, 0:1, V:7, 0:1, W:7, T/binary>> ->
            {ok, {{pitch, C, (W bsl 7) bor V}, T}};

        _ ->
            {error, baddata}

    end.
