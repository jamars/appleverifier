-module(appleverifier_server).

-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% API
-export([test/1]).

-define(SERVER, ?MODULE).

-record(aws_config_state, {aws_access_key_id = "", aws_secret_access_key = "", aws_region = "us-east-1"}).
-record(aws_resources_state, {sqs_url = "", ddb_url = ""}).
-record(aws_params_state, {in_queue = "", ddb_table = ""}).
-record(apple_params_state, {apple_api_url_state = "https://sandbox.itunes.apple.com"}).
-record(state, { aws_config_state, aws_params_state, aws_resources_state, apple_params_state }).

getSingleMessageFromAwsResponse([{messages, []}|_]) ->
    [];

getSingleMessageFromAwsResponse([{messages, [R|_]}|_]) ->
    io:format("~ngetSingleMessageFromAwsResponse: ~p~n", [R]),
    R.

getBodyFromMessage([]) ->
    [];

getBodyFromMessage(M) when is_list(M) ->
    Raw = proplists:get_value(body, M),
    case Decoded = Raw =:= [] orelse jsx:decode(list_to_binary(Raw)) of
        true -> [];
        _ -> Decoded
    end.

create_aws_config_for_sqs(AWS_CFG, AWS_SQS_URL)
  when is_record(AWS_CFG, aws_config_state) ->
    erlcloud_config:new(AWS_CFG#aws_config_state.aws_access_key_id , AWS_CFG#aws_config_state.aws_secret_access_key, AWS_SQS_URL).

create_aws_config_for_ddb(AWS_CFG, AWS_DDB_URL)
  when is_record(AWS_CFG, aws_config_state) ->
    erlcloud_config:new(AWS_CFG#aws_config_state.aws_access_key_id , AWS_CFG#aws_config_state.aws_secret_access_key, AWS_DDB_URL).

create_sqs_outbound_message(UserId, TransactionId, Status) ->
    "{\"user_id\": " ++ integer_to_list(UserId) ++ ", \"transaction_id\": \"" ++ binary_to_list(TransactionId) ++ "\", \"status\": \"" ++ Status ++ "\"}".

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    % Build server state from environment config
    AWS_CONF_ENV = application:get_env(erlcloud, aws_config),
    {ok, Aws_Config_List} = AWS_CONF_ENV,
    AWS_CONF_STATE = #aws_config_state{
        aws_access_key_id = proplists:get_value(aws_access_key_id, Aws_Config_List),
        aws_secret_access_key = proplists:get_value(aws_secret_access_key, Aws_Config_List) },
    
    {ok, AWS_PARAMS}   = application:get_env(appleverifier, aws_params),
    AWS_PARAMS_STATE = #aws_params_state{
        in_queue  = proplists:get_value(in_queue, AWS_PARAMS),
        ddb_table = proplists:get_value(ddb_table, AWS_PARAMS)
        },

    {ok, AWS_RESOURCES_ENV} = application:get_env(appleverifier, aws_resources),
    io:format("~n~p AWS_RESOURCES: ~p~n", [?FUNCTION_NAME, AWS_RESOURCES_ENV]),
    AWS_RESOURCES_SQS_URL_ENV = proplists:get_value(sqs_url, AWS_RESOURCES_ENV),
    AWS_RESOURCES_DDB_URL_ENV = proplists:get_value(ddb_url, AWS_RESOURCES_ENV),
    AWS_RESOURCES_STATE = #aws_resources_state{
        sqs_url = AWS_RESOURCES_SQS_URL_ENV,
        ddb_url = AWS_RESOURCES_DDB_URL_ENV
        },
    
    {ok, APPLE_PARAMS} = application:get_env(appleverifier, apple_params),
    APPLE_PARAMS_STATE = #apple_params_state{apple_api_url_state = proplists:get_value(apple_api_url, APPLE_PARAMS)},

    State = #state{
        aws_config_state = AWS_CONF_STATE,
        aws_params_state = AWS_PARAMS_STATE,
        aws_resources_state = AWS_RESOURCES_STATE,
        apple_params_state = APPLE_PARAMS_STATE },

    erlang:send_after(1000, self(), polling_loop),
    {ok, State}.

handle_call({test, S}, _From, State) ->
    {reply, S, State};

handle_call(stop, _From, State) ->
    {stop, normal, stopped, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(polling_loop, State) ->
    io:format("~n~p POLLING~n", [?FUNCTION_NAME]),
    %% TODO: sqs polling returning up to 10 messages and delete batch them after processing...

    %% Receive message
    SQS_CONFIG = create_aws_config_for_sqs(
            State#state.aws_config_state,
            ((State#state.aws_resources_state)#aws_resources_state.sqs_url)),
    R = erlcloud_sqs:receive_message(
        ((State#state.aws_params_state)#aws_params_state.in_queue),
        all,
        1,
        30,
        15,
        all,
        SQS_CONFIG),

    %% Get the proplist of the 1st message inside messages tuple from the enclosing array
    M = getSingleMessageFromAwsResponse(R),
    %% Extract message body with business data
    MessageBody = getBodyFromMessage(M),
    SQSReceipt = proplists:get_value(receipt_handle, M),

    %% Process message

    %% Create aws config for dynamoDB access
    DDB_CONFIG = create_aws_config_for_ddb(
        State#state.aws_config_state,
        ((State#state.aws_resources_state)#aws_resources_state.ddb_url)
    ),
    case verify_with_apple(MessageBody, ((State#state.apple_params_state)#apple_params_state.apple_api_url_state)) of
        {ok, UserId, OutQ, TransactionId} -> 
            BusinessResult = verify_business_transaction((State#state.aws_params_state)#aws_params_state.ddb_table, TransactionId, DDB_CONFIG),
            inform_outcome(BusinessResult, UserId, TransactionId, OutQ, SQS_CONFIG),
            remove_message_from_inbound_queue(SQSReceipt, SQS_CONFIG),
            reschedule_poll(State);
        {invalid, UserId, OutQ, TransactionId} ->
            inform_outcome(invalid, UserId, TransactionId, OutQ, SQS_CONFIG),
            remove_message_from_inbound_queue(SQSReceipt, SQS_CONFIG),
            reschedule_poll(State);
        _ ->
            %% No messages, Poll again, assume an HTTP transient error
            %% and will retry later
            reschedule_poll(State)
    end;

handle_info(Info, State) ->
    io:format("handle_info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

test(S) -> 
    io:format("~ntest called on ~p~n", [?MODULE]),
    gen_server:call(?MODULE, {test, S}).

verify_with_apple([], _) ->
    {empty};

%% TODO: handle malformed messages?
verify_with_apple(M, APPLE_API_URL) ->
    Receipt = proplists:get_value(<<"receipt">>, M),
    UserId = proplists:get_value(<<"user_id">>, M),
    OutQ = proplists:get_value(<<"post_queue">>, M),

    io:format("~n~p UserId: ~p~n", [?FUNCTION_NAME, UserId]),
    io:format("~n~p OutQ: ~p~n", [?FUNCTION_NAME, OutQ]),

    case appleverifier_apple_requests:verify_receipt(Receipt, APPLE_API_URL) of
        {ok, TransactionId} ->
            {ok, UserId, OutQ, TransactionId};
        {invalid, TransactionId} ->
            {invalid, UserId, OutQ, TransactionId};
        {error, _} ->
            io:format("~n~p Error", [?FUNCTION_NAME]),
            {error, UserId, OutQ}
    end.

reschedule_poll(State) ->
    %% Schedule the next Polling
    %% TODO: grab hardcoded time interval from State/Configuration
    erlang:send_after(1000, self(), polling_loop),
    {noreply, State}.

create_put_expression(TransactionId) ->
    {<<"transaction_id">>, TransactionId}.

create_condition_expression() ->
    {condition_expression, <<"attribute_not_exists(transaction_id)">>}.

verify_business_transaction(DDBtable, TransactionId, DDB_CONFIG) ->
    io:format("~n~p Table: ~p TransactionId: ~p~n", [?FUNCTION_NAME, DDBtable, TransactionId]),
    case erlcloud_ddb2:put_item(DDBtable, [create_put_expression(TransactionId)], [create_condition_expression()], DDB_CONFIG) of
        {ok,[]} ->
            io:format("~n~p TransactionId ~p was written to database~n", [?FUNCTION_NAME, TransactionId]),
            ok;
        {error,{<<"ConditionalCheckFailedException">>,<<>>}} ->
            io:format("~n~p TransactionId ~p was already processed, will not send out message~n", [?FUNCTION_NAME, TransactionId]),
            invalid;
        Unexpected ->
            io:format("~n~p TransactionId ~p unexpected error (~p) accessing database~n", [?FUNCTION_NAME, TransactionId, Unexpected]),
            no_send %% ?? API failure - shouldn't remove from in queue?
    end.

%% close business transaction by sending result to out queue
inform_outcome(ok, UserId, TransactionId, OutQ, Config) ->
    erlcloud_sqs:send_message(OutQ, create_sqs_outbound_message(UserId, TransactionId, "OK"), Config);

inform_outcome(invalid, UserId, TransactionId, OutQ, Config) ->
    erlcloud_sqs:send_message(OutQ, create_sqs_outbound_message(UserId, TransactionId, "INVALID"), Config);

inform_outcome(_, _, _, _, _) -> [].


remove_message_from_inbound_queue(SQSReceipt, Config) ->
    erlcloud_sqs:delete_message("AppleReceiptsQueue", SQSReceipt, Config).
