%%==============================================================================
%% Copyright 2010 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================
%% @author Ulf Wiger <ulf.wiger@erlang-solutions.com>
%% @copyright 2010 Erlang Solutions Ltd 
%% @end
%% =====================================================================

%% @doc EDoc Doclet module for producing Github-flavored Markdown.

%% TODO: copy "doc-files" subdirectories, recursively.
%% TODO: generate summary page of TODO-notes
%% TODO: generate summary page of deprecated things
%% TODO: generate decent indexes over modules, methods, records, etc.

-module(edown_doclet).

-export([run/2]).

-import(edoc_report, [report/2, warning/2]).

%% @headerfile "edoc_doclet.hrl"
-include_lib("edoc/include/edoc_doclet.hrl").

-define(EDOC_APP, edoc).
-define(DEFAULT_FILE_SUFFIX, ".md").
-define(INDEX_FILE, "index.md").
-define(OVERVIEW_FILE, "overview.edoc").
-define(PACKAGE_SUMMARY, "package-summary.md").
-define(OVERVIEW_SUMMARY, "overview-summary.md").
-define(PACKAGES_FRAME, "packages-frame.md").
-define(MODULES_FRAME, "modules-frame.md").
-define(STYLESHEET, "stylesheet.css").
-define(IMAGE, "erlang.png").
-define(NL, "\n").

-include_lib("xmerl/include/xmerl.hrl").

%% Sources is the list of inputs in the order they were found.  Packages
%% and Modules are sorted lists of atoms without duplicates. (They
%% usually include the data from the edoc-info file in the target
%% directory, if it exists.) Note that the "empty package" is never
%% included in Packages!

%% @spec (Command::doclet_gen() | doclet_toc(), edoc_context()) -> ok
%% @doc Main doclet entry point. 
%%
%% Also see {@link edoc:layout/2} for layout-related options, and
%% {@link edoc:get_doc/2} for options related to reading source
%% files.
%%
%% Options:
%% <dl>
%%  <dt>{@type {file_suffix, string()@}}
%%  </dt>
%%  <dd>Specifies the suffix used for output files. The default value is
%%      `".md"'.
%%  </dd>
%%  <dt>{@type {hidden, bool()@}}
%%  </dt>
%%  <dd>If the value is `true', documentation of hidden modules and
%%      functions will also be included. The default value is `false'.
%%  </dd>
%%  <dt>{@type {overview, edoc:filename()@}}
%%  </dt>
%%  <dd>Specifies the name of the overview-file. By default, this doclet
%%      looks for a file `"overview.edoc"' in the target directory.
%%  </dd>
%%  <dt>{@type {private, bool()@}}
%%  </dt>
%%  <dd>If the value is `true', documentation of private modules and
%%      functions will also be included. The default value is `false'.
%%  </dd>
%%  <dt>{@type {stylesheet, string()@}}
%%  </dt>
%%  <dd>Specifies the URI used for referencing the stylesheet. The
%%      default value is `"stylesheet.css"'. If an empty string is
%%      specified, no stylesheet reference will be generated.
%%  </dd>
%%  <dt>{@type {stylesheet_file, edoc:filename()@}}
%%  </dt>
%%  <dd>Specifies the name of the stylesheet file. By default, this
%%      doclet uses the file `"stylesheet.css"' in the `priv'
%%      subdirectory of the EDoc installation directory. The named file
%%      will be copied to the target directory.
%%  </dd>
%%  <dt>{@type {title, string()@}}
%%  </dt>
%%  <dd>Specifies the title of the overview-page.
%%  </dd>
%% </dl>

%% INHERIT-OPTIONS: title/2
%% INHERIT-OPTIONS: sources/5
%% INHERIT-OPTIONS: overview/4
%% INHERIT-OPTIONS: copy_stylesheet/2
%% INHERIT-OPTIONS: stylesheet/1

run(#doclet_gen{}=Cmd, Ctxt) ->
    gen(Cmd#doclet_gen.sources,
	Cmd#doclet_gen.app,
	Cmd#doclet_gen.packages,
	Cmd#doclet_gen.modules,
	Cmd#doclet_gen.filemap,
	Ctxt);
run(#doclet_toc{}=Cmd, Ctxt) ->
    toc(Cmd#doclet_toc.paths, Ctxt).

gen(Sources, App, Packages, Modules, FileMap, Ctxt) ->
    Dir = Ctxt#context.dir,
    Env = Ctxt#context.env,
    Options0 = Ctxt#context.opts,
    Options = [{layout,edown_layout},
	       {file_suffix,".md"}
	       | Options0],
    Title = title(App, Options),
    %% CSS = stylesheet(Options),
    {Modules1, Error} = sources(Sources, Dir, Modules, Env, Options),
    packages(Packages, Dir, FileMap, Env, Options),
    Overview = overview(Dir, Title, Env, Options),
    Data = 
	[{h1, [Title]}]
	 ++ Overview
	 ++ lists:concat([packages_frame(Packages) || Packages =/= []])
	 ++ lists:concat([modules_frame(Modules1) || Modules1 =/= []]),

    Text = xmerl:export_simple_content(Data, edown_xmerl),
    edoc_lib:write_file(Text, Dir, ?INDEX_FILE),
    edoc_lib:write_info_file(App, Packages, Modules1, Dir),
    copy_stylesheet(Dir, Options),
    copy_image(Dir),
    %% handle postponed error during processing of source files
    case Error of
	true -> exit(error);
	false -> ok
    end.

%% Tried to display logo in a table on top of page, but not working.
%% Presumably, this hits some limitation of GFM
%%
%% logo() ->
%%     {img, [{src, "erlang.png"},{alt,["Erlang logo"]}],[]}.

%% NEW-OPTIONS: title
%% DEFER-OPTIONS: run/2

title(App, Options) ->
    proplists:get_value(title, Options,
			if App == ?NO_APP ->
				"Overview";
			   true ->
				io_lib:fwrite("Application: ~s", [App])
			end).


%% Processing the individual source files.

%% NEW-OPTIONS: file_suffix, private, hidden
%% INHERIT-OPTIONS: edoc:layout/2
%% INHERIT-OPTIONS: edoc:get_doc/3
%% DEFER-OPTIONS: run/2

sources(Sources, Dir, Modules, Env, Options) ->
    Suffix = proplists:get_value(file_suffix, Options,
				 ?DEFAULT_FILE_SUFFIX),
    Private = proplists:get_bool(private, Options),
    Hidden = proplists:get_bool(hidden, Options),
    {Ms, E} = lists:foldl(fun (Src, {Set, Error}) ->
				  source(Src, Dir, Suffix, Env, Set,
					 Private, Hidden, Error, Options)
			  end,
			  {sets:new(), false}, Sources),
    {[M || M <- Modules, sets:is_element(M, Ms)], E}.


%% Generating documentation for a source file, adding its name to the
%% set if it was successful. Errors are just flagged at this stage,
%% allowing all source files to be processed even if some of them fail.

source({M, P, Name, Path}, Dir, Suffix, Env, Set, Private, Hidden,
       Error, Options) ->
    File = filename:join(Path, Name),
    case catch {ok, edoc:get_doc(File, Env, Options)} of
	{ok, {Module, Doc}} ->
	    check_name(Module, M, P, File),
	    case ((not is_private(Doc)) orelse Private)
		andalso ((not is_hidden(Doc)) orelse Hidden) of
		true ->
		    Text = edoc:layout(Doc, Options),
		    Name1 = packages:last(M) ++ Suffix,
		    edoc_lib:write_file(Text, Dir, Name1, P),
		    {sets:add_element(Module, Set), Error};
		false ->
		    {Set, Error}
	    end;
	R ->
	    report("skipping source file '~s': ~W.", [File, R, 15]),
	    {Set, true}
    end.

check_name(M, M0, P0, File) ->
    P = list_to_atom(packages:strip_last(M)),
    N = packages:last(M),
    N0 = packages:last(M0),
    case N of
	[$? | _] ->
	    %% A module name of the form '?...' is assumed to be caused
	    %% by the epp_dodger parser when the module declaration has
	    %% the form '-module(?MACRO).'; skip the filename check.
	    ok;
	_ ->
	    if N =/= N0 ->
		    warning("file '~s' actually contains module '~s'.",
			    [File, M]);
	       true ->
		    ok
	    end
    end,
    if P =/= P0 ->
	    warning("file '~s' belongs to package '~s', not '~s'.",
		    [File, P, P0]);
       true ->
	    ok
    end.


%% Generating the summary files for packages.

%% INHERIT-OPTIONS: read_file/4
%% INHERIT-OPTIONS: edoc_lib:run_layout/2

packages(Packages, Dir, FileMap, Env, Options) ->
    lists:foreach(fun (P) ->
			  package(P, Dir, FileMap, Env, Options)
		  end,
		  Packages).

package(P, Dir, FileMap, Env, Opts) ->
    Tags = case FileMap(P) of
	       "" ->
		   [];
	       File ->
		   read_file(File, package, Env, Opts)
	   end,
    Data = edoc_data:package(P, Tags, Env, Opts),
    F = fun (M) ->
		M:package(Data, Opts)
	end,
    Text = edoc_lib:run_layout(F, Opts),
    edoc_lib:write_file(Text, Dir, ?PACKAGE_SUMMARY, P).



packages_frame(Ps) ->
    [{h2, [{class, "indextitle"}], ["Packages"]},
     {table, [{width, "100%"}, {border, 0},
	      {summary, "list of packages"}],
      lists:concat(
	[[{tr, [{td, [], [{a, [{href, package_ref(P)},
			       {class, "package"}],
			   [atom_to_list(P)]}]}]}]
	 || P <- Ps])}].


modules_frame(Ms) ->
    [{h2, [{class, "indextitle"}], ["Modules"]},
     {table, [{width, "100%"}, {border, 0},
	      {summary, "list of modules"}],
      lists:concat(
	[[?NL,
	  {tr, [{td, [],
		 [{a, [{href, module_ref(M)},
		       {class, "module"}],
		   [atom_to_list(M)]}]}]}]
	 || M <- Ms])}].

module_ref(M) ->
    edoc_refs:relative_package_path(M, '') ++ ?DEFAULT_FILE_SUFFIX.

package_ref(P) ->
    edoc_lib:join_uri(edoc_refs:relative_package_path(P, ''),
		      ?PACKAGE_SUMMARY).


%% xhtml(Title, CSS, Content) ->
%%     xhtml_1(Title, CSS, {body, [{bgcolor, "white"}], Content}).

%% xhtml_1(Title, CSS, Body) ->
%%     {html, [?NL,
%% 	    {head, [?NL, {title, [Title]}, ?NL] ++ CSS},
%% 	    ?NL,
%% 	    Body,
%% 	    ?NL]
%%     }.

%% NEW-OPTIONS: overview
%% INHERIT-OPTIONS: read_file/4
%% INHERIT-OPTIONS: edoc_lib:run_layout/2
%% INHERIT-OPTIONS: edoc_extract:file/4
%% DEFER-OPTIONS: run/2

overview(Dir, Title, Env, Opts) ->
    File = proplists:get_value(overview, Opts,
			       filename:join(Dir, ?OVERVIEW_FILE)),
    Tags = read_file(File, overview, Env, Opts),
    Data = edoc_data:overview(Title, Tags, Env, Opts),
    F = fun (M) ->
		M:overview(Data, Opts)
	end,
    _Markdown = edoc_lib:run_layout(F, Opts).
    %% edoc_lib:write_file(Text, Dir, ?OVERVIEW_SUMMARY).


copy_image(Dir) ->
    case code:priv_dir(?EDOC_APP) of
	PrivDir when is_list(PrivDir) ->
	    From = filename:join(PrivDir, ?IMAGE),
	    edoc_lib:copy_file(From, filename:join(Dir, ?IMAGE));
	_ ->
	    report("cannot find default image file.", []),
	    exit(error)
    end.

%% NEW-OPTIONS: stylesheet_file
%% DEFER-OPTIONS: run/2

copy_stylesheet(Dir, Options) ->
    case proplists:get_value(stylesheet, Options) of
	undefined ->
	    From = case proplists:get_value(stylesheet_file, Options) of
		       File when is_list(File) ->
			   File;
		       _ ->
			   case code:priv_dir(?EDOC_APP) of
			       PrivDir when is_list(PrivDir) ->
				   filename:join(PrivDir, ?STYLESHEET);
			       _ ->
				   report("cannot find default "
					  "stylesheet file.", []),
				   exit(error)
			   end
		   end,
	    edoc_lib:copy_file(From, filename:join(Dir, ?STYLESHEET));
	_ ->
	    ok
    end.

%% NEW-OPTIONS: stylesheet
%% DEFER-OPTIONS: run/2

%% stylesheet(Options) ->
%%     case proplists:get_value(stylesheet, Options) of
%% 	"" ->
%% 	    [];
%% 	S ->
%% 	    Ref = case S of
%% 		      undefined ->
%% 			  ?STYLESHEET;
%% 		      "" ->
%% 			  "";    % no stylesheet
%% 		      S when is_list(S) ->
%% 			  S;
%% 		      _ ->
%% 			  report("bad value for option 'stylesheet'.",
%% 				 []),
%% 			  exit(error)
%% 		  end,
%% 	    [{link, [{rel, "stylesheet"},
%% 		     {type, "text/css"},
%% 		     {href, Ref},
%% 		     {title, "EDoc"}], []},
%% 	     ?NL]
%%     end.

is_private(E) ->
    case get_attrval(private, E) of
 	"yes" -> true;
 	_ -> false
    end.

is_hidden(E) ->
    case get_attrval(hidden, E) of
 	"yes" -> true;
 	_ -> false
    end.

get_attrval(Name, #xmlElement{attributes = As}) ->
    case get_attr(Name, As) of
	[#xmlAttribute{value = V}] ->
	    V;
	[] -> ""
    end.

get_attr(Name, [#xmlAttribute{name = Name} = A | As]) ->
    [A | get_attr(Name, As)];
get_attr(Name, [_ | As]) ->
    get_attr(Name, As);
get_attr(_, []) ->
    [].

%% Read external source file. Fails quietly, returning empty tag list.

%% INHERIT-OPTIONS: edoc_extract:file/4

read_file(File, Context, Env, Opts) ->
    case edoc_extract:file(File, Context, Env, Opts) of
	{ok, Tags} ->
	    Tags;
	{error, _} ->
	    []
    end.


%% TODO: FIXME: meta-level index generation

%% Creates a Table of Content from a list of Paths (ie paths to applications)
%% and an overview file.

-define(EDOC_DIR, "doc").
-define(INDEX_DIR, "doc/index").
-define(CURRENT_DIR, ".").

toc(_Paths, _Ctxt) ->
    erlang:error(nyi).
    %% Opts = Ctxt#context.opts,
    %% Dir = Ctxt#context.dir,
    %% Env = Ctxt#context.env,
    %% app_index_file(Paths, Dir, Env, Opts).

%% TODO: FIXME: it's unclear how much of this is working at all

%% NEW-OPTIONS: title
%% INHERIT-OPTIONS: overview/4

%% app_index_file(Paths, Dir, Env, Options) ->
%%     Title = proplists:get_value(title, Options,"Overview"),
%% %    Priv = proplists:get_bool(private, Options),
%%     CSS = stylesheet(Options),
%%     Apps1 = [{filename:dirname(A),filename:basename(A)} || A <- Paths],
%%     index_file(Dir, false, Title),
%%     application_frame(Dir, Apps1, Title, CSS),
%%     modules_frame(Dir, [], Title, CSS),
%%     overview(Dir, Title, Env, Options),
%% %    edoc_lib:write_info_file(Prod, [], Modules1, Dir),
%%     copy_stylesheet(Dir, Options).

%% application_frame(Dir, Apps, Title, CSS) ->
%%     Body = [?NL,
%% 	    {h2, ["Applications"]},
%% 	    ?NL,
%% 	    {table, [{width, "100%"}, {border, 0}],
%% 	     lists:concat(
%% 	       [[{tr, [{td, [], [{a, [{href,app_ref(Path,App)},
%% 				      {target,"_top"}],
%% 				  [App]}]}]}]
%% 		|| {Path,App} <- Apps])},
%% 	    ?NL],
%%     XML = xhtml(Title, CSS, Body),
%%     Text = xmerl:export_simple([XML], xmerl_html, []),
%%     edoc_lib:write_file(Text, Dir, ?MODULES_FRAME).

%% app_ref(Path,M) ->
%%     filename:join([Path,M,?EDOC_DIR,?INDEX_FILE]).
