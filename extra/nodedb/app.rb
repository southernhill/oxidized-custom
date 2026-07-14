# frozen_string_literal: true

# Minimal web UI to add/edit/remove nodes in the sqlite inventory used by
# the Oxidized SQL source. Run with: bundle exec ruby app.rb
#
# Environment:
#   NODEDB_PATH        path to the sqlite database (default ./nodes.db)
#   NODEDB_UI_PORT     listen port (default 8889)
#   NODEDB_UI_BIND     listen address (default 0.0.0.0)
#   NODEDB_UI_USER     basic-auth user (auth disabled unless PASSWORD is set)
#   NODEDB_UI_PASSWORD basic-auth password (omit when an authenticating
#                      reverse proxy like oauth2-proxy fronts the UI)
#   NODEDB_UI_PREFIX   URL prefix when served under a subpath of a reverse
#                      proxy, e.g. "/nodedb"
#   OXIDIZED_URL       oxidized-web base URL for node reload after changes
#                      (default http://127.0.0.1:8888, empty string disables)

require 'sinatra'
require 'sequel'
require 'net/http'

DB_PATH = ENV.fetch('NODEDB_PATH', File.join(__dir__, 'nodes.db'))
DB = Sequel.connect(adapter: 'sqlite', database: DB_PATH)
DB.run File.read(File.join(__dir__, 'schema.sql'))
NODES = DB[:nodes]

MODELS = %w[ios iosxr nxos eos junos fortios panos procurve aruba routeros
            fastiron ironware nos edgeswitch edgeos airos xos ciscosmb
            cumulus cumulusold asa vyos linuxgeneric].freeze

PREFIX = ENV.fetch('NODEDB_UI_PREFIX', '').chomp('/')

set :bind, ENV.fetch('NODEDB_UI_BIND', '0.0.0.0')
set :port, ENV.fetch('NODEDB_UI_PORT', 8889).to_i
enable :sessions

# strip the proxy prefix so routes below stay prefix-agnostic
unless PREFIX.empty?
  use(Class.new do
    def initialize(app)
      @app = app
    end

    def call(env)
      path = env['PATH_INFO']
      unless path == PREFIX || path.start_with?("#{PREFIX}/")
        return [404, { 'content-type' => 'text/plain' }, ["not found (UI is served under #{PREFIX}/)"]]
      end

      env['SCRIPT_NAME'] = PREFIX
      stripped = path.delete_prefix(PREFIX)
      env['PATH_INFO'] = stripped.empty? ? '/' : stripped
      @app.call(env)
    end
  end)
end

if ENV['NODEDB_UI_PASSWORD']
  use Rack::Auth::Basic, 'oxidized nodedb' do |user, pass|
    Rack::Utils.secure_compare(user, ENV.fetch('NODEDB_UI_USER', 'admin')) &
      Rack::Utils.secure_compare(pass, ENV['NODEDB_UI_PASSWORD'])
  end
end

helpers do
  def h(text)
    Rack::Utils.escape_html(text.to_s)
  end

  def u(path)
    "#{PREFIX}#{path}"
  end

  def node_params
    row = {}
    %w[name ip model node_group username password enable].each do |f|
      v = params[f].to_s.strip
      row[f.to_sym] = v.empty? ? nil : v
    end
    port = params['ssh_port'].to_s.strip
    row[:ssh_port] = port.empty? ? nil : port.to_i
    row
  end

  # Ask oxidized to re-read the source so changes apply without waiting
  # for the next interval. Best effort - the UI still works if it fails.
  def reload_oxidized
    base = ENV.fetch('OXIDIZED_URL', 'http://127.0.0.1:8888')
    return 'oxidized reload disabled' if base.empty?

    Net::HTTP.get_response(URI("#{base}/reload?format=json"))
    'oxidized node list reloaded'
  rescue StandardError => e
    "oxidized reload failed: #{e.message}"
  end
end

get '/' do
  @nodes = NODES.order(:node_group, :name).all
  @flash = session.delete(:flash)
  erb :index
end

post '/nodes' do
  row = node_params
  if row[:name].nil? || row[:model].nil?
    session[:flash] = 'name and model are required'
  elsif NODES.where(name: row[:name]).any?
    session[:flash] = "#{row[:name]} already exists"
  else
    NODES.insert(row)
    session[:flash] = "#{row[:name]} added (#{reload_oxidized})"
  end
  redirect u('/')
end

get '/nodes/:id/edit' do
  @node = NODES.first(id: params['id'].to_i) or halt 404, 'no such node'
  erb :edit
end

post '/nodes/:id' do
  id = params['id'].to_i
  halt 404, 'no such node' unless NODES.where(id: id).any?
  row = node_params
  if row[:name].nil? || row[:model].nil?
    session[:flash] = 'name and model are required'
  elsif NODES.exclude(id: id).where(name: row[:name]).any?
    session[:flash] = "#{row[:name]} already exists"
  else
    NODES.where(id: id).update(row.merge(updated_at: Sequel.lit("datetime('now')")))
    session[:flash] = "#{row[:name]} updated (#{reload_oxidized})"
  end
  redirect u('/')
end

post '/nodes/:id/delete' do
  node = NODES.first(id: params['id'].to_i) or halt 404, 'no such node'
  NODES.where(id: node[:id]).delete
  session[:flash] = "#{node[:name]} deleted (#{reload_oxidized})"
  redirect u('/')
end

__END__

@@ layout
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>oxidized nodedb</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {
    --bg: #ffffff; --fg: #26262b; --muted: #86868c; --line: #ececee;
    --hover: #f7f7f8; --input-bg: #ffffff; --btn-bg: #f4f4f5; --btn-hover: #ebebec;
    --focus: #a3a3ab; --danger: #c53030; --flash-bg: #f7f7f8;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #131315; --fg: #dcdcde; --muted: #7e7e86; --line: #26262a;
      --hover: #1a1a1d; --input-bg: #18181b; --btn-bg: #202024; --btn-hover: #29292e;
      --focus: #5b5b64; --danger: #ef8a8a; --flash-bg: #1a1a1d;
    }
  }
  * { box-sizing: border-box; }
  body {
    font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg); color: var(--fg);
    max-width: 66em; margin: 0 auto; padding: 2em 2em 3em;
    -webkit-font-smoothing: antialiased;
  }
  h1 { font-size: 1em; font-weight: 600; letter-spacing: .01em; margin: 0 0 1.2em; }
  h1 .count { color: var(--muted); font-weight: 400; }
  h2 { font-size: .78em; font-weight: 600; text-transform: uppercase;
       letter-spacing: .07em; color: var(--muted); margin: 2em 0 .9em; }
  table { border-collapse: collapse; width: 100%; }
  th, td { padding: .42em .65em; text-align: left; border-bottom: 1px solid var(--line); }
  th { font-size: .7em; font-weight: 500; text-transform: uppercase;
       letter-spacing: .07em; color: var(--muted);
       position: sticky; top: 0; background: var(--bg); }
  .search { display: flex; align-items: baseline; gap: .9em; margin-bottom: 1em; }
  .search input { width: 19em; }
  .search .matches { font-size: .85em; color: var(--muted); }
  tbody tr:hover { background: var(--hover); }
  td.empty { color: var(--muted); text-align: center; padding: 2.5em; }
  .mono { font-variant-numeric: tabular-nums; }
  .muted { color: var(--muted); }
  .pill { font-size: .78em; padding: .05em .55em; border: 1px solid var(--line);
          border-radius: 999px; color: var(--muted); white-space: nowrap; }
  .pill.override { border-color: var(--danger); color: var(--danger); }
  a { color: inherit; }
  td .actions { display: flex; gap: .9em; align-items: baseline; justify-content: flex-end;
                visibility: hidden; }
  tbody tr:hover .actions { visibility: visible; }
  td .actions a { color: var(--muted); text-decoration: none; }
  td .actions a:hover { color: var(--fg); text-decoration: underline; }
  form.inline { display: inline; }
  .flash { background: var(--flash-bg); border: 1px solid var(--line); border-radius: 6px;
           padding: .5em .9em; margin-bottom: 1.2em; font-size: .9em; }
  fieldset { border: none; margin: 0 0 .3em; padding: 0;
             display: flex; flex-wrap: wrap; gap: .9em 1.1em; align-items: flex-end; }
  fieldset + fieldset { margin-top: 1.6em; }
  legend { font-size: .7em; font-weight: 600; text-transform: uppercase;
           letter-spacing: .07em; color: var(--muted); padding: 0;
           width: 100%; margin-bottom: .3em; }
  legend .hint { text-transform: none; letter-spacing: normal; font-weight: 400; }
  label { display: flex; flex-direction: column; gap: .25em;
          font-size: .78em; color: var(--muted); }
  input {
    font: inherit; font-size: .95em; color: var(--fg); background: var(--input-bg);
    border: 1px solid var(--line); border-radius: 6px; padding: .38em .6em; width: 11em;
    -webkit-appearance: none; appearance: none; box-shadow: none;
  }
  input:focus { outline: none; border-color: var(--focus); }
  input.short { width: 6em; }
  input[type="search"]::-webkit-search-cancel-button {
    -webkit-appearance: none; height: .8em; width: .8em; cursor: pointer;
    background: var(--muted);
    -webkit-mask: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 4l8 8M12 4l-8 8' stroke='black' stroke-width='2' stroke-linecap='round'/%3E%3C/svg%3E") center / contain no-repeat;
  }
  input[type="search"]::-webkit-search-cancel-button:hover { background: var(--fg); }
  input[type="number"]::-webkit-inner-spin-button,
  input[type="number"]::-webkit-outer-spin-button { -webkit-appearance: none; margin: 0; }
  button {
    font: inherit; font-size: .92em; font-weight: 500; cursor: pointer; border-radius: 6px;
    border: 1px solid var(--line); background: var(--btn-bg); color: var(--fg);
    padding: .35em .85em;
    -webkit-appearance: none; appearance: none; box-shadow: none;
  }
  button:hover { background: var(--btn-hover); }
  button.del {
    background: none; border: none; color: var(--muted); padding: 0;
    font-size: inherit; font-weight: 400;
  }
  button.del:hover { color: var(--danger); text-decoration: underline; background: none; }
  .formcard { border: 1px solid var(--line); border-radius: 8px; padding: 1.1em 1.3em .3em; }
  .formcard button[type=submit], .formcard .submit { margin: 1.2em 0 1em; }
  details.add { margin-bottom: 1.2em; }
  details.add summary {
    display: inline-block; cursor: pointer; list-style: none; user-select: none;
    font-size: .92em; font-weight: 500; border: 1px solid var(--line); border-radius: 6px;
    background: var(--btn-bg); color: var(--fg); padding: .35em .85em;
  }
  details.add summary::before { content: "+"; margin-right: .45em; color: var(--muted); }
  details.add summary::-webkit-details-marker { display: none; }
  details.add summary:hover { background: var(--btn-hover); }
  details.add[open] summary { margin-bottom: 1em; }
  details.add[open] summary::before { content: "\2013"; }
  .cancel { font-size: .92em; color: var(--muted); margin-left: 1em; text-decoration: none; }
  .cancel:hover { color: var(--fg); text-decoration: underline; }
</style>
</head>
<body>
<h1>oxidized nodes <% if @nodes %><span class="count">· <%= @nodes.size %></span><% end %></h1>
<%= erb :flash if @flash %>
<%= yield %>
</body>
</html>

@@ flash
<div class="flash"><%= h @flash %></div>

@@ fields
<fieldset>
  <legend>node</legend>
  <label>name<br><input name="name" required value="<%= h node[:name] %>"></label>
  <label>ip<br><input name="ip" value="<%= h node[:ip] %>"></label>
  <label>model<br><input name="model" list="models" required value="<%= h node[:model] %>">
    <datalist id="models"><% MODELS.each do |m| %><option value="<%= m %>"><% end %></datalist></label>
  <label>group<br><input name="node_group" value="<%= h node[:node_group] %>"></label>
  <label>ssh port<br><input class="short" name="ssh_port" type="number" min="1" max="65535" placeholder="22" value="<%= h node[:ssh_port] %>"></label>
</fieldset>
<fieldset>
  <legend>credential overrides <span class="hint">(leave empty to use the shared credentials from the oxidized config)</span></legend>
  <label>username<br><input name="username" autocomplete="off" value="<%= h node[:username] %>"></label>
  <label>password<br><input name="password" type="password" autocomplete="off" value="<%= h node[:password] %>"></label>
  <label>enable<br><input name="enable" type="password" autocomplete="off" value="<%= h node[:enable] %>"></label>
</fieldset>

@@ index
<details class="add">
  <summary>add node</summary>
  <div class="formcard">
  <form method="post" action="<%= u "/nodes" %>">
    <%= erb :fields, locals: { node: {} } %>
    <div class="submit"><button>add node</button></div>
  </form>
  </div>
</details>

<div class="search">
  <input id="q" type="search" placeholder="filter by name, ip, model or group" autocomplete="off">
  <span class="matches" id="matches"></span>
</div>
<table>
  <thead>
    <tr><th>name</th><th>ip</th><th>model</th><th>group</th><th>ssh port</th><th>creds</th><th></th></tr>
  </thead>
  <tbody>
  <% @nodes.each do |n| %>
  <tr data-search="<%= h [n[:name], n[:ip], n[:model], n[:node_group]].compact.join(' ').downcase %>">
    <td><%= h n[:name] %></td>
    <td class="mono"><%= h n[:ip] %></td>
    <td><%= h n[:model] %></td>
    <td class="muted"><%= h n[:node_group] %></td>
    <td class="mono"><%= n[:ssh_port] || 22 %></td>
    <td><span class="pill<%= ' override' if n[:username] || n[:password] || n[:enable] %>">
      <%= n[:username] || n[:password] || n[:enable] ? 'override' : 'shared' %></span></td>
    <td><div class="actions">
      <a href="<%= u "/nodes/#{n[:id]}/edit" %>">edit</a>
      <form class="inline" method="post" action="<%= u "/nodes/#{n[:id]}/delete" %>"
            onsubmit="return confirm('Delete <%= h n[:name] %>?')">
        <button class="del">delete</button>
      </form>
    </div></td>
  </tr>
  <% end %>
  <% if @nodes.empty? %><tr><td colspan="7" class="empty">no nodes yet, add the first one above</td></tr><% end %>
  </tbody>
</table>

<script>
  var q = document.getElementById('q');
  var matches = document.getElementById('matches');
  var rows = Array.prototype.slice.call(document.querySelectorAll('tbody tr[data-search]'));
  q.addEventListener('input', function () {
    var term = q.value.trim().toLowerCase();
    var shown = 0;
    rows.forEach(function (row) {
      var hit = !term || row.dataset.search.indexOf(term) !== -1;
      row.style.display = hit ? '' : 'none';
      if (hit) shown++;
    });
    matches.textContent = term ? shown + ' of ' + rows.length : '';
  });
</script>

@@ edit
<h2>edit <%= h @node[:name] %></h2>
<div class="formcard">
<form method="post" action="<%= u "/nodes/#{@node[:id]}" %>">
  <%= erb :fields, locals: { node: @node } %>
  <div class="submit"><button>save changes</button><a class="cancel" href="<%= u "/" %>">cancel</a></div>
</form>
</div>
