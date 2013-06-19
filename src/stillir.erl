-module(stillir).

-export([init/0,
         set_config/1,
         set_config/3,
         set_config/4,
         get_config/2,
         get_config/3,
         update_env/2]).

-type app_name() :: atom().
-type app_key() :: atom().
-type env_key() :: string().
-type env_var_value() :: string().
-type app_key_value() :: any().
-type default_value() :: app_key_value().
-type transform_fun() :: fun(((env_var_value())) -> app_key_value()).
-type transform() :: integer|float|binary|atom|transform_fun().
-type opt() :: {default, any()}|{transform, transform()}.
-type opts() :: [opt()]|[].
-type config_tuple() :: {app_name(), app_key(), env_key()}|
                        {app_name(), app_key(), env_key(), opts()}.

-spec init() -> ok.
init() ->
    stillir = ets:new(stillir, [public, named_table]),
    ok.

-spec set_config([config_tuple()]|[]) -> ok|no_return().
set_config([]) ->
    ok;
set_config([{AppName, AppKey, EnvKey}|Rest]) ->
    set_config(AppName, AppKey, EnvKey),
    set_config(Rest);
set_config([{AppName, AppKey, EnvKey, Opts}|Rest]) ->
    set_config(AppName, AppKey, EnvKey, Opts),
    set_config(Rest).

-spec set_config(app_name(), app_key(), env_key()) -> ok|no_return().
set_config(AppName, AppKey, EnvKey) ->
    set_config(AppName, AppKey, EnvKey, []).

-spec set_config(app_name(), app_key(), env_key(),
                 opts()) -> ok|no_return().
set_config(AppName, AppKey, EnvKey, Opts) ->
    save_mapping(AppName, AppKey, EnvKey, Opts),
    EnvValue = get_env(EnvKey),
    set_env_value(AppName, AppKey, EnvKey, EnvValue, Opts).

-spec get_config(app_name(), app_key()) -> app_key_value()|no_return().
get_config(AppName, AppKey) ->
    case application:get_env(AppName, AppKey) of
        undefined ->
            erlang:error({missing_config, AppKey});
        {ok, Val} ->
            Val
    end.

-spec get_config(app_name(), app_key(), default_value()) -> app_key_value().
get_config(AppName, AppKey, DefaultValue) ->
    case application:get_env(AppName, AppKey) of
        undefined ->
            DefaultValue;
        {ok, Val} ->
            Val
    end.

-spec update_env(app_name(), file:filename_all()) -> ok|no_return().
update_env(Application, Filename) ->
    case file:open(Filename, [read, raw]) of
        {ok, IoDev} ->
            NewValues = read_file(IoDev, []),
            reread_environment(Application, NewValues);
        {error, _Error} = Error ->
            Error
    end.

%% Internal
transform_value(Value, undefined) when is_list(Value) ->
    Value;
transform_value(Value, integer) when is_list(Value) ->
    list_to_integer(Value);
transform_value(Value, float) when is_list(Value) ->
    list_to_float(Value);
transform_value(Value, binary) when is_list(Value) ->
    list_to_binary(Value);
transform_value(Value, atom) when is_list(Value) ->
    list_to_atom(Value);
transform_value(Value, Fun) when is_function(Fun, 1) andalso is_list(Value) ->
    Fun(Value);
transform_value(Value, _) ->
    Value.

reread_environment(_AppName, []) ->
    ok;
reread_environment(AppName, [no_match|Rest]) ->
    reread_environment(AppName, Rest);
reread_environment(AppName, [{EnvKey, EnvVar}|Rest]) ->
    case ets:lookup(stillir, {AppName, EnvKey}) of
        [] ->
            error_logger:info_msg("app=stillir at=reread_environment warning=unmapped env variable"),
            reread_environment(AppName, Rest);
        [{{AppName, EnvKey}, {AppKey, Opts}}] ->
            true = os:putenv(EnvKey, EnvVar),
            set_config(AppName, AppKey, EnvKey, Opts),
            reread_environment(AppName, Rest)
    end.

save_mapping(AppName, AppKey, EnvKey, Opts) ->
    ets:insert(stillir, {{AppName, EnvKey}, {AppKey, Opts}}).

get_env(EnvKey) ->
    case os:getenv(EnvKey) of
        false ->
            missing_env_key;
        EnvValue ->
            {value, EnvValue}
    end.

set_env_value(AppName, AppKey, EnvKey, missing_env_key, Opts) ->
    case proplists:is_defined(default, Opts) of
        true ->
            DefaultValue = proplists:get_value(default, Opts),
            set_env_value(AppName, AppKey, EnvKey, {value, DefaultValue}, Opts);
        false ->
            erlang:error({missing_env_key, {AppName, EnvKey}})
    end;
set_env_value(AppName, AppKey, _, {value, EnvValue}, Opts) ->
    Transform = proplists:get_value(transform, Opts),
    TransformedValue = transform_value(EnvValue, Transform),
    set_env(AppName, AppKey, TransformedValue).

set_env(AppName, AppKey, Value) ->
    application:set_env(AppName, AppKey, Value).

read_file(IoDev, Retval) ->
    case file:read_line(IoDev) of
        {ok, Data} ->
            Res = handle_line(Data),
            read_file(IoDev, Retval ++ [Res]);
        eof ->
            Retval;
        {error, _Error} = Error ->
            Error
    end.

handle_line(Data) ->
    case re:split(Data, "^export\s+([A-Z0-9_]+)='(.*)'\n$") of
        [_, EnvKey, EnvVar, _] ->
            {binary_to_list(EnvKey), binary_to_list(EnvVar)};
        Error ->
            error_logger:info_msg("app=stillir at=handle_line error=~p", [Error]),
            no_match
    end.
