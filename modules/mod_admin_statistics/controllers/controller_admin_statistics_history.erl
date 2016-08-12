%% @author Maas-Maarten Zeeman <tahteche@gmail.com>
%% @copyright 2016 Tah Teche Tende
%% @doc View zotonic system statistics history

%% Copyright 2016 Tah Teche Tende
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(controller_admin_statistics_history).
-author("Tah Teche Tende <tahteche@gmail.com>").

-export([
    is_authorized/2
]).

-include_lib("controller_html_helper.hrl").

is_authorized(ReqData, Context) ->
    z_admin_controller_helper:is_authorized(mod_admin_statistics, ReqData, Context).

html(Context) ->
    Vars = [
        {page_admin_statistics, true}
    ],
    Html = z_template:render("admin_statistics_history.tpl", Vars, Context),
    z_context:output(Html, Context).
