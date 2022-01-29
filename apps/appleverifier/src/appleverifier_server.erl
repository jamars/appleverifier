-module(appleverifier_server).

-behaviour(gen_server).

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(aws_config_state, {aws_access_key_id = "", aws_secret_access_key = "", aws_region = "us-east-1"}).
-record(aws_resources_state, {sqs_url = "", ddb_url = ""}).
-record(aws_params_state, {in_queue = "", ddb_table = ""}).
-record(apple_params_state, {apple_api_url_state = "https://sandbox.itunes.apple.com"}).
-record(state, { aws_config_state, aws_params_state, aws_resources_state, apple_params_state }).

start_link(Name) ->
    logger:info("Starting ~p", [Name]),
    gen_server:start_link({local, Name}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(2000, self(), polling_loop),
    {ok, create_state_from_app_config()}.

handle_call({test, S}, _From, State) ->
    {reply, S, State};

handle_call(stop, _From, State) ->
    {stop, normal, stopped, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(polling_loop, State) ->
    logger:info("~p POLLING", [?FUNCTION_NAME]),
    % Extract required info from State
    { InQueueName,
      DDBTableName,
      AppleApiUrl,
      SQSConfig,
      DDBConfig } = extract_from_state(State),

    %% Extract message body with business data
    {MessageBody, SQSReceipt} =
          get_body_and_receipt_from_message(
            poll_sqs(InQueueName, SQSConfig)),

    %% Process message
    case verify_with_apple(MessageBody, AppleApiUrl) of
        {ok, UserId, OutQueueName, TransactionId} ->
            BusinessResult = verify_business_transaction(DDBTableName, TransactionId, DDBConfig),
            inform_outcome(BusinessResult, UserId, TransactionId, OutQueueName, SQSConfig),
            remove_message_from_inbound_queue(SQSReceipt, SQSConfig);

        {invalid, UserId, OutQueueName, TransactionId} ->
            inform_outcome(invalid, UserId, TransactionId, OutQueueName, SQSConfig),
            remove_message_from_inbound_queue(SQSReceipt, SQSConfig);

        %% Receiving empty means there was no message to process
        %% and there's nothing to do
        empty ->
            [];

        %% Probably an HTTP transient error
        %% will retry later
        Unexpected ->
            logger:error("~n~p Unexpected error: ~p~n", [?FUNCTION_NAME, Unexpected])
    end,
    %% Reschedule polling for new messages
    reschedule_poll(State);

handle_info(Info, State) ->
    logger:notice("handle_info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Private module functions

create_state_from_app_config() ->
    % Build server state from environment config
    AwsConfEnv = application:get_env(erlcloud, aws_config),
    {ok, Aws_Config_List} = AwsConfEnv,
    AwsConfState = #aws_config_state{
        aws_access_key_id = proplists:get_value(aws_access_key_id, Aws_Config_List),
        aws_secret_access_key = proplists:get_value(aws_secret_access_key, Aws_Config_List) },

    {ok, AwsParams} = application:get_env(appleverifier, aws_params),
    AwsParamsState = #aws_params_state{
        in_queue = proplists:get_value(in_queue, AwsParams),
        ddb_table = proplists:get_value(ddb_table, AwsParams)
        },

    {ok, AwsResourcesEnv} = application:get_env(appleverifier, aws_resources),
    AwsResourcesSqsUrlEnv = proplists:get_value(sqs_url, AwsResourcesEnv),
    AwsResourcesDdbUrlEnv = proplists:get_value(ddb_url, AwsResourcesEnv),
    AwsResourcesState = #aws_resources_state{
        sqs_url = AwsResourcesSqsUrlEnv,
        ddb_url = AwsResourcesDdbUrlEnv
        },

    {ok, AppleParams} = application:get_env(appleverifier, apple_params),
    AppleParamsState = #apple_params_state{apple_api_url_state = proplists:get_value(apple_api_url, AppleParams)},

    #state{
        aws_config_state = AwsConfState,
        aws_params_state = AwsParamsState,
        aws_resources_state = AwsResourcesState,
        apple_params_state = AppleParamsState}.

extract_from_state(State) when is_record(State, state) ->
    #state{
        aws_config_state = AWSConfig,
        aws_resources_state =
            #aws_resources_state{
                sqs_url = SQSUrl,
                ddb_url = DDBUrl
            },
        aws_params_state =
            #aws_params_state{
                in_queue = InQueueName,
                ddb_table = DDBTableName
            },
        apple_params_state =
            #apple_params_state{
                apple_api_url_state = AppleApiUrl
            }
    } = State,
    %% Create aws config for SQS access
    SQSConfig = create_aws_config_for_sqs(AWSConfig, SQSUrl),
    %% Create aws config for DynamoDB access
    DDBConfig = create_aws_config_for_ddb(AWSConfig, DDBUrl),

    {
     InQueueName,
     DDBTableName,
     AppleApiUrl,
     SQSConfig,
     DDBConfig
    }.

%% Poll AWS SQS Queue
%% TODO: SQS polling returning up to 10 messages and delete batch them after processing...
%% TODO: add Visibility timeout to State (read from app config)
%% TODO: add Polling timeout to State (read from app config)
poll_sqs(QueueName, AwsConfig) ->
    get_single_message_from_sqs_response(
        erlcloud_sqs:receive_message(
            QueueName,
            all,
            1,  %% Retrieve one message
            30, %% Set AWS SQS Visibility Timeout for read message
            15, %% AWS SQS Polling Timeout
            all,
            AwsConfig)).

get_single_message_from_sqs_response([{messages, []}|_]) ->
    [];

%% SQS messages are returned by ercloud_sqs:receive_message with format
%% [{messages, [...]}, ...]
%% This function returns the first element of the list
%% in the tuple {messages, [...]}
get_single_message_from_sqs_response([{messages, [R|_]}|_]) ->
    logger:info("~ngetSingleMessageFromAwsResponse: ~p~n", [R]),
    R.

get_body_and_receipt_from_message([]) ->
    {[], undefined};

get_body_and_receipt_from_message(M) when is_list(M) ->
    Body = get_body_from_message(M),
    {Body, proplists:get_value(receipt_handle, M)}.

get_body_from_message([]) ->
    [];

get_body_from_message(M) when is_list(M) ->
    Raw = proplists:get_value(body, M),
    case Decoded = Raw =:= [] orelse jsx:decode(list_to_binary(Raw)) of
        true -> [];
        _ -> Decoded
    end.

create_aws_config_for_sqs(AwsCfg, AwsSqsUrl)
  when is_record(AwsCfg, aws_config_state) ->
    erlcloud_config:new(AwsCfg#aws_config_state.aws_access_key_id , AwsCfg#aws_config_state.aws_secret_access_key, AwsSqsUrl).

create_aws_config_for_ddb(AwsCfg, AwsDdbUrl)
  when is_record(AwsCfg, aws_config_state) ->
    erlcloud_config:new(AwsCfg#aws_config_state.aws_access_key_id , AwsCfg#aws_config_state.aws_secret_access_key, AwsDdbUrl).

create_sqs_outbound_message(UserId, TransactionId, Status) ->
    "{\"user_id\": " ++ integer_to_list(UserId) ++ ", \"transaction_id\": \"" ++ binary_to_list(TransactionId) ++ "\", \"status\": \"" ++ Status ++ "\"}".

verify_with_apple([], _) ->
    empty;

%% TODO: handle malformed messages?
verify_with_apple(M, AppleApiUrl) ->
    Receipt = proplists:get_value(<<"receipt">>, M),
    UserId = proplists:get_value(<<"user_id">>, M),
    OutQ = proplists:get_value(<<"post_queue">>, M),

    logger:debug("~n~p UserId: ~p~n", [?FUNCTION_NAME, UserId]),
    logger:debug("~n~p OutQ: ~p~n", [?FUNCTION_NAME, OutQ]),

    case appleverifier_apple_requests:verify_receipt(Receipt, AppleApiUrl) of
        {ok, TransactionId} ->
            {ok, UserId, OutQ, TransactionId};
        {invalid, TransactionId} ->
            {invalid, UserId, OutQ, TransactionId};
        {error, _} ->
            logger:error("~n~p Error", [?FUNCTION_NAME]),
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

verify_business_transaction(DDBtable, TransactionId, DdbConfig) ->
    logger:info("~n~p Table: ~p TransactionId: ~p~n", [?FUNCTION_NAME, DDBtable, TransactionId]),
    case erlcloud_ddb2:put_item(DDBtable, [create_put_expression(TransactionId)], [create_condition_expression()], DdbConfig) of
        {ok,[]} ->
            logger:info("~n~p TransactionId ~p was written to database~n", [?FUNCTION_NAME, TransactionId]),
            ok;
        {error,{<<"ConditionalCheckFailedException">>,<<>>}} ->
            logger:warning("~n~p TransactionId ~p was already processed, will send invalid message~n", [?FUNCTION_NAME, TransactionId]),
            invalid;
        Unexpected ->
            logger:error("~n~p TransactionId ~p unexpected error (~p) accessing database~n", [?FUNCTION_NAME, TransactionId, Unexpected]),
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
