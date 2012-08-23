%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP, INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(wh_service_plans).

-include_lib("whistle_services/src/whistle_services.hrl").

-export([empty/0]).
-export([public_json/1]).
-export([from_service_json/1]).
-export([plan_summary/1]).
-export([activation_charges/3]).
-export([create_items/1
         ,create_items/2
        ]).

-record(wh_service_plans, {vendor_id = undefined
                           ,plans = []
                          }).

-type(plans() :: [#wh_service_plans{},...] | []).
-export_type([plans/0]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Create an empty service plans data structure.
%% @end
%%--------------------------------------------------------------------
-spec empty/0 :: () -> plans().
empty() -> [].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec from_service_json/1 :: (wh_json:json_object()) -> plans().
from_service_json(ServicesJObj) ->
    PlanIds = wh_json:get_keys(<<"plans">>, ServicesJObj),
    ResellerId = wh_json:get_value(<<"pvt_reseller_id">>, ServicesJObj),
    get_plans(PlanIds, ResellerId, ServicesJObj).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
public_json(ServicePlans) ->
    public_json(ServicePlans, wh_json:new()).

public_json([], JObj) ->
    JObj;
public_json([#wh_service_plans{plans=Plans}|ServicePlans], JObj) ->
    NewJObj = lists:foldl(fun(P, J) -> 
                                  wh_json:merge_recursive(J, wh_json:get_value(<<"plan">>, P, wh_json:new()))
                          end, JObj, Plans),
    public_json(ServicePlans, NewJObj).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec plan_summary/1 :: (wh_json:json_object()) -> wh_json:json_object().
plan_summary(ServicesJObj) ->
    ResellerId = wh_json:get_value(<<"pvt_reseller_id">>, ServicesJObj),
    lists:foldl(fun(PlanId, J) ->
                        Plan = wh_json:get_value([<<"plans">>, PlanId], ServicesJObj, wh_json:new()),
                        case wh_json:get_value(<<"account_id">>, Plan) of
                            ResellerId -> wh_json:set_value(PlanId, Plan, J);
                            _Else -> J
                        end
                end, wh_json:new(), wh_json:get_keys(<<"plans">>, ServicesJObj)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec activation_charges/3 :: (ne_binary(), ne_binary(), plans()) -> float().
activation_charges(Category, Item, ServicePlans) ->
    Plans = [Plan
             || ServicePlan <- ServicePlans
                    ,Plan <- ServicePlan#wh_service_plans.plans
            ],
    lists:foldl(fun(Plan, Charges) ->
                        wh_service_plan:activation_charges(Category, Item, Plan) 
                            + Charges
                end, 0.0, Plans).
    
%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given a the services on an account (and descedants) as well as the
%% service plans the account is subscribed to create a list of items
%% suitable for use with the bookkeepers.
%% @end
%%--------------------------------------------------------------------
-spec create_items/1 :: (wh_json:json_object()) -> {'ok', wh_service_items:items()} | {'error', 'no_plans'}.
-spec create_items/2 :: (wh_services:services(), plans()) -> wh_service_items:items().

create_items(ServiceJObj) ->
    Services = wh_services:from_service_json(ServiceJObj),
    case from_service_json(ServiceJObj) of
        [] -> {error, no_plans};
        ServicePlans ->
            {ok, create_items(Services, ServicePlans)}
    end.

create_items(Services, ServicePlans) ->
    Plans = [Plan
             || ServicePlan <- ServicePlans
                    ,Plan <- ServicePlan#wh_service_plans.plans
            ],
    lists:foldl(fun(Plan, Items) ->
                        wh_service_plan:create_items(Plan, Items, Services)
                end, wh_service_items:empty(), Plans).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% For each plans object fetch the service plan and store it
%% in the vendors #wh_service_plans data structure.
%% @end
%%--------------------------------------------------------------------
-spec get_plans/3 :: ([ne_binary(),...] | [], ne_binary(), wh_json:json_object()) -> plans().
-spec get_plans/4 :: ([ne_binary(),...] | [], ne_binary(), wh_json:json_object(), plans()) -> plans().

get_plans(PlanIds, ResellerId, Sevices) ->
    get_plans(PlanIds, ResellerId, Sevices, empty()).

get_plans([], _, _, ServicePlans) ->
    ServicePlans;
get_plans([PlanId|PlanIds], ResellerId, Services, ServicePlans) ->
    VendorId = wh_json:get_value([<<"plans">>, PlanId, <<"account_id">>], Services, ResellerId),
    Overrides = wh_json:get_value([<<"plans">>, PlanId, <<"overrides">>], Services, wh_json:new()),
    case maybe_fetch_vendor_plan(PlanId, VendorId, ResellerId, Overrides) of
        undefined -> get_plans(PlanIds, ResellerId, Services, ServicePlans);
        Plan -> get_plans(PlanIds, ResellerId, Services, append_vendor_plan(Plan, VendorId, ServicePlans))
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec maybe_fetch_vendor_plan/4 :: (ne_binary(), ne_binary(), ne_binary(), wh_json:json_object())
                                   -> 'undefined' | wh_json:json_object().
maybe_fetch_vendor_plan(PlanId, VendorId, VendorId, Overrides) ->
    wh_service_plan:fetch(PlanId, VendorId, Overrides);
maybe_fetch_vendor_plan(PlanId, _, ResellerId, _) ->
    lager:debug("service plan ~s doesnt belong to reseller ~s", [PlanId, ResellerId]),
    undefined.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Given a plan and a vendor id append it to the list of service plans
%% for that vendor, creating a new list (record) if not present.
%% @end
%%--------------------------------------------------------------------
-spec append_vendor_plan/3 :: (wh_service_plan:plan(), ne_binary(), plans()) -> plans().
append_vendor_plan(Plan, VendorId, ServicePlans) ->
    case lists:keyfind(VendorId, #wh_service_plans.vendor_id, ServicePlans) of
        false -> 
            ServicePlan = #wh_service_plans{vendor_id=VendorId
                                            ,plans=[Plan]},
            [ServicePlan|ServicePlans];
        #wh_service_plans{plans=Plans}=ServicePlan ->
            lists:keyreplace(VendorId, #wh_service_plans.vendor_id, ServicePlans
                             ,ServicePlan#wh_service_plans{plans=[Plan|Plans]})
    end.
