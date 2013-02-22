-module(heimdall_actors_resource).

-include("heimdall_wm_rest_endpoint.hrl").

-export([allowed_methods/2,
         create_path/2,
         from_json/2,
         init/1]).

init(Config) ->
    heimdall_wm_base:init(?MODULE, Config).

allowed_methods(Req, State) ->
    {['POST'], Req, State}.

create_path(Req, State) ->
    {"/actors", Req, State}.

validate_request(Req, State) ->
    % We really don't care if there's a requestor or not, so we just take whatever
    % comes back, even if the requestor_id remains undefined.
    State0 = heimdall_wm_util:get_requestor(Req, State),
    {false, Req, State0}.

auth_info(_Method) ->
    {any}.

from_json(Req, State) ->
    AuthzId = heimdall_wm_util:generate_authz_id(),
    % Attempt to store actor in DB
    % Attempt to add actor to own ACL
    % Attempt to add requestor to ACL
    Req0 = heimdall_wm_util:set_created_response(Req, AuthzId),
    {ok, Req0, State}.
