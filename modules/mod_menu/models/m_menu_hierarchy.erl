%% @copyright 2015 Marc Worrell
%% @doc Model for named hierarchies

%% Copyright 2015 Marc Worrell
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

-module(m_menu_hierarchy).

-export([
    m_find_value/3,
    m_to_list/2,
    m_value/2,
    tree/2,
    tree_flat/2,
    menu/2,
    ensure/2,
    save/3,
    install/1
    ]).

-include_lib("zotonic.hrl").

% Default delta between hierarchy items to minimize renumbering
-define(DELTA,     1000000).
-define(DELTA_MIN, 1000).
-define(DELTA_MAX, 2000000000). % ~ 1^31


m_find_value(Name, #m{value=undefined} = M, _Context) ->
    M#m{value=Name};
m_find_value(tree, #m{value=Name}, Context) ->
    tree(Name, Context);
m_find_value(tree_flat, #m{value=Name}, Context) ->
    tree_flat(Name, Context);
m_find_value(menu, #m{value=Name}, Context) ->
    menu(Name, Context);
m_find_value(_Key, _Value, _Context) ->
    undefined.

m_to_list(#m{value=undefined}, _Context) ->
    [];
m_to_list(#m{value=Category}, Context) ->
    tree(Category, Context);
m_to_list(_, _Context) ->
    [].

m_value(#m{value=#m{value=Name}}, Context) ->
    tree(Name, Context).


%% @doc Fetch a named tree
tree(undefined, _Context) ->
    [];
tree(<<>>, _Context) ->
    [];
tree(Id, Context) when is_integer(Id) ->
    tree(m_rsc:p_no_acl(Id, name, Context), Context);
tree(Name, Context) when is_binary(Name) ->
    F = fun() ->
        CatTuples = z_db:q("
                select id, parent_id, lvl 
                from menu_hierarchy 
                where name = $1
                order by nr", 
                [Name],
                Context),
        build_tree(CatTuples, [])
    end,
    z_depcache:memo(F, {menu_hierarchy, Name}, ?DAY, [menu_hierarchy], Context);
tree(Name, Context) ->
    tree(z_convert:to_binary(Name), Context).

%% @doc Make a flattened list with indentations showing the level of the tree entries.
%%      Useful for select lists.
tree_flat(Name, Context) ->
    List = flatten_tree(tree(Name, Context)),
    [ 
        [{indent,indent(proplists:get_value(level, E, 0))} | E ]
        || E <- List
    ].

%% @doc Transform a hierarchy to a menu structure
menu(Name, Context) ->
    tree_to_menu(tree(Name, Context), []).

tree_to_menu([], Acc) ->
    lists:reverse(Acc);
tree_to_menu([E|Rest], Acc) ->
    {id, Id} = proplists:lookup(id, E),
    {children, Cs} = proplists:lookup(children, E),
    Cs1 = tree_to_menu(Cs, []),
    tree_to_menu(Rest, [{Id,Cs1}|Acc]).


%% @doc Ensure that all resources are present in a hierarchy.
ensure(Category, Context) ->
    case m_category:name_to_id(Category, Context) of
        {ok, CatId} ->
            Name = m_rsc:p_no_acl(CatId, name, Context),
            Ids = z_db:q("select id from menu_hierarchy where name = $1", [Name], Context),
            F = fun(Id, Acc, _Ctx) ->
                    case lists:member(Id, Ids) of
                        true -> Acc;
                        false -> [Id|Acc]
                    end
                end,
            Missing = m_category:fold(CatId, F, [], Context),
            append(Name, Missing, Context);
        {error, _} = Error ->
            Error
    end.

%% @doc Save a new hierarchy, replacing a previous one.
save(Name, Tree, Context) ->
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            case m_category:name_to_id(Name, Context) of
                {ok, CatId} ->
                    save_1(CatId, Tree, Context);
                {error, _} = Error ->
                    lager:warning("[menu_hierarchy] Hierarchy save for unknown category ~p", [Name]),
                    Error
            end;
        false ->
            {error, eacces}
    end.

save_1(CatId, NewTree, Context) ->
    Name = m_rsc:p_no_acl(CatId, name, Context),
    NewFlat = flatten_save_tree(NewTree),
    OldFlatNr = z_db:q("
                select id, parent_id, lvl, nr
                from menu_hierarchy 
                where name = $1
                order by nr", 
                [Name],
                Context),
    OldFlat = [ {Id,P,Lvl} || {Id,P,Lvl,_Nr} <- OldFlatNr ],
    Diff = diffy_term:diff(OldFlat, NewFlat),
    NewFlatNr = assign_nrs(Diff, OldFlatNr),

    OldIds = [ Id || {Id, _P, _Lvl, _Nr} <- OldFlatNr ],
    NewIds = [ Id || {Id, _P, _Lvl, _Nr} <- NewFlatNr ],
    InsIds = NewIds -- OldIds,
    UpdIds = NewIds -- InsIds,
    DelIds = OldIds -- NewIds,

    z_db:transaction(fun(Ctx) ->
            lists:foreach(fun(Id) ->
                            {Id, P, Lvl, Nr} = lists:keyfind(Id, 1, NewFlatNr),
                            {Left,Right} = range(Id, NewFlatNr),
                            z_db:q("
                                    insert into menu_hierarchy
                                        (name, id, parent_id, lvl, nr, lft, rght)
                                    values
                                        ($1, $2, $3, $4, $5, $6, $7)",
                                   [Name, Id, P, Lvl, Nr, Left, Right],
                                   Ctx)
                          end,
                          InsIds),
            lists:foreach(fun(Id) ->
                            {Id, P, Lvl, Nr} = lists:keyfind(Id, 1, NewFlatNr),
                            {Left,Right} = range(Id, NewFlatNr),
                            z_db:q("
                                    update menu_hierarchy
                                    set parent_id = $3,
                                        lvl = $4,
                                        nr = $5,
                                        lft = $6,
                                        rght = $7
                                    where name = $1
                                      and id = $2
                                      and (  parent_id <> $3
                                          or lvl <> $4
                                          or nr <> $5
                                          or lft <> $6
                                          or rght <> $7)",
                                   [Name, Id, P, Lvl, Nr, Left, Right],
                                   Ctx)
                          end,
                          UpdIds),
            lists:foreach(fun(Id) ->
                            z_db:q("delete from menu_hierarchy
                                    where name = $1 and id = $2",
                                   [Name,Id],
                                   Ctx)
                          end,
                          DelIds),
            ok
        end,
        Context),
    flush(Name, Context),
    ok.

range(Id, [{Id,_P,Lvl,Nr}|Rest]) ->
    Right = range_1(Lvl, Nr, Rest),
    {Nr,Right};
range(Id, [_|Rest]) ->
    range(Id, Rest).

range_1(Lvl, _Max, [{_Id,_P,Lvl1,Nr}|Rest]) when Lvl > Lvl1 ->
    range_1(Lvl, Nr, Rest);
range_1(_Lvl, Max, _Rest) ->
    Max.

assign_nrs(Diff, OldFlatNr) ->
    IdNr = lists:foldl(fun({Id,_,_,Nr}, D) ->
                            dict:store(Id, Nr, D)
                       end,
                       dict:new(),
                       OldFlatNr),
    assign_nrs_1(Diff, [], 0, IdNr).

assign_nrs_1([], Acc, _LastNr, _IdNr) ->
    lists:reverse(Acc);
assign_nrs_1([{_Op, []}|Rest], Acc, LastNr, IdNr) ->
    assign_nrs_1(Rest, Acc, LastNr, IdNr);
assign_nrs_1([{equal, [{Id,P,Lvl}|Rs]}|Rest], Acc, LastNr, IdNr) ->
    PrevNr = dict:fetch(Id, IdNr),
    case erlang:max(PrevNr,LastNr+1) of
        PrevNr ->
            Acc1 = [{Id,P,Lvl,PrevNr} | Acc],
            assign_nrs_1([{equal, Rs}|Rest], Acc1, PrevNr, IdNr);
        _ ->
            Diff1 = [{equal, Rs}|Rest],
            NewNr = case next_equal_nr(Diff1, IdNr) of
                        undefined ->
                            LastNr + ?DELTA;
                        EqNr when EqNr >= LastNr + 2 ->
                            LastNr + (EqNr-LastNr) div 2
                    end,
            Acc1 = [{Id,P,Lvl,NewNr} | Acc],
            assign_nrs_1(Diff1, Acc1, NewNr, IdNr)
    end;
assign_nrs_1([{insert, [{Id,P,Lvl}|Rs]}|Rest], Acc, LastNr, IdNr) ->
    CurrNr = case dict:find(Id, IdNr) of
                {ok, Nr} -> Nr;
                error -> undefined
             end,
    NextEq = next_equal_nr(Rest, IdNr),
    NewNr = if
                CurrNr =:= undefined, NextEq =:= undefined ->
                    LastNr + ?DELTA;
                NextEq =:= undefined, CurrNr > LastNr ->
                    CurrNr;
                NextEq =/= undefined, CurrNr > LastNr, NextEq > CurrNr ->
                    CurrNr;
                NextEq =/= undefined, NextEq >= LastNr + 2 ->
                    erlang:min(LastNr+?DELTA, LastNr + (NextEq-LastNr) div 2);
                true ->
                    % We have to shift the NextEq, as it is =< LastNr+2
                    LastNr + ?DELTA_MIN
            end,
    Acc1 = [{Id,P,Lvl,NewNr} | Acc],
    assign_nrs_1([{insert, Rs}|Rest], Acc1, NewNr, IdNr);
assign_nrs_1([{delete, _}|Rest], Acc, LastNr, IdNr) ->
    assign_nrs_1(Rest, Acc, LastNr, IdNr).


next_equal_nr(Diff, IdNr) ->
    case next_equal(Diff) of
        undefined -> undefined;
        Id -> dict:fetch(Id, IdNr)
    end.

next_equal([]) -> undefined;
next_equal([{equal, [{Id,_,_}|_]}|_]) -> Id;
next_equal([_|Ds]) -> next_equal(Ds).

flatten_save_tree(Tree) ->
    lists:reverse(flatten_save_tree(Tree, undefined, 1, [])).

flatten_save_tree([], _ParentId, _Lvl, Acc) ->
    Acc;
flatten_save_tree([{Id, Cs}|Ts], ParentId, Lvl, Acc) ->
    Acc1 = flatten_save_tree(Cs, Id, Lvl+1, [{Id,ParentId,Lvl}|Acc]),
    flatten_save_tree(Ts, ParentId, Lvl, Acc1).

append(_Name, [], _Context) ->
    ok;
append(Name0, Missing, Context) ->
    Name = z_convert:to_binary(Name0),
    Nr = next_nr(Name0, Context),
    lists:foldl(fun(Id, NextNr) ->
                    z_db:q("
                        insert into menu_hierarchy (name, id, nr, lft, rght)
                        values ($1, $2, $3, $4, $5)",
                        [Name, Id, NextNr, NextNr, NextNr]),
                    NextNr+?DELTA
                end,
                Nr,
                Missing),
    flush(Name, Context).


next_nr(Name, Context) ->
    case z_db:q1("select max(nr) from menu_hierarchy where name = $1", [Name], Context) of
        undefined -> ?DELTA;
        Nr -> Nr + ?DELTA
    end.

flush(Name, Context) ->
    z_depcache:flush({menu_hierarchy, Name}, Context).


indent(Level) when Level =< 0 ->
    <<>>;
indent(Level) when is_integer(Level) ->
    iolist_to_binary(string:copies("&nbsp;&nbsp;&nbsp;&nbsp;", Level-1)).

flatten_tree(Tree) ->
    lists:reverse(flatten_tree(Tree, [], [])).

flatten_tree([], _Path, Acc) ->
    Acc;
flatten_tree([E|Ts], Path, Acc) ->
    Acc1 = [ [{path,Path}|E] | Acc ],
    Path1 = [ proplists:get_value(id, E) | Path ],
    Acc2 = flatten_tree(proplists:get_value(children, E, []), Path1, Acc1),
    flatten_tree(Ts, Path, Acc2).


%% @doc Build a tree from the queried arguments
build_tree([], Acc) ->
    lists:reverse(Acc);
build_tree([{_Id, _Parent, _Lvl} = C|Rest], Acc) ->
    {C1, Rest1} = build_tree(C, [], Rest),
    build_tree(Rest1, [C1|Acc]).
    
build_tree({Id, _Parent, _Lvl} = P, Acc, [{_Id2, Parent2, _Lvl2} = C|Rest])
    when Id == Parent2 ->
    {C1, Rest1} = build_tree(C, [], Rest),
    build_tree(P, [C1|Acc], Rest1);
build_tree({Id, Parent, Lvl}, Acc, Rest) ->
    {[{id,Id}, {parent_id,Parent}, {level,Lvl}, {children, lists:reverse(Acc)}], Rest}.




install(Context) ->
    case z_db:table_exists(menu_hierarchy, Context) of
        false ->
            create_table(Context),
            z_db:flush(Context),
            ok;
        true ->
            ok
    end.

create_table(Context) ->
    [] = z_db:q("
        CREATE TABLE menu_hierarchy (
          name character varying (80),
          id int NOT NULL,
          parent_id int,
          nr int NOT NULL DEFAULT 0,
          lvl int NOT NULL DEFAULT 0,
          lft int NOT NULL DEFAULT 0,
          rght int NOT NULL DEFAULT 0,

          CONSTRAINT menu_hierarchy_pkey PRIMARY KEY (name, id),
          CONSTRAINT fk_menu_hierarchy_id FOREIGN KEY (id)
            REFERENCES rsc(id)
            ON UPDATE CASCADE ON DELETE CASCADE
        )", Context),
    z_db:q("CREATE INDEX menu_hierarchy_nr_key ON menu_hierarchy (name, nr)", Context),
    ok.

