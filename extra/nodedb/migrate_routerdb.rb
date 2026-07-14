#!/usr/bin/env ruby
# frozen_string_literal: true

# Imports a semicolon-delimited router.db into the sqlite node inventory.
#
#   ruby migrate_routerdb.rb /home/oxidized/routerdb/router.db /home/oxidized/nodedb/nodes.db
#
# Expected router.db columns (matching the old csv source map):
#   name;ip;model;username;password;group;enable;ssh_port
#
# By default secrets (username/password/enable) are NOT imported - the point
# of the migration is to move them into the oxidized config as group/global
# credentials. The script prints the distinct credential sets it found per
# group so you can copy them into the config.
#
# When credentials are heterogeneous, pass the global defaults you intend to
# put in the oxidized config and the script stores per-device overrides ONLY
# where a device differs (per field):
#
#   ruby migrate_routerdb.rb router.db nodes.db \
#     --default-username=backup --default-password='TheCommonPass'
#
# Pass --with-secrets to import all per-device credentials unconditionally.

require 'sequel'

with_secrets = ARGV.delete('--with-secrets')
defaults = {}
ARGV.delete_if do |arg|
  next false unless arg =~ /\A--default-(username|password|enable)=(.*)\z/m

  defaults[Regexp.last_match(1).to_sym] = Regexp.last_match(2)
  true
end
src, dst = ARGV
abort "usage: #{$PROGRAM_NAME} ROUTER_DB SQLITE_DB [--with-secrets] " \
      "[--default-username=U] [--default-password=P] [--default-enable=E]" unless src && dst
abort "#{src}: no such file" unless File.exist?(src)

db = Sequel.connect(adapter: 'sqlite', database: dst)
db.run File.read(File.join(__dir__, 'schema.sql'))
nodes = db[:nodes]

imported = 0
overrides = 0
skipped = []
creds = Hash.new(0)

File.foreach(src) do |line|
  line = line.strip
  next if line.empty? || line.start_with?('#')

  name, ip, model, username, password, group, enable, ssh_port = line.split(';').map do |f|
    f = f.to_s.strip
    # oxidized's csv source turns the literal string "nil" into nil
    f.empty? || f == 'nil' ? nil : f
  end

  unless name && model
    skipped << line
    next
  end

  creds[[group, username, password, enable]] += 1

  row = {
    name:       name,
    ip:         ip,
    model:      model,
    node_group: group,
    ssh_port:   ssh_port&.to_i
  }
  if with_secrets
    row[:username] = username
    row[:password] = password
    row[:enable]   = enable
  elsif defaults.any?
    # store only the fields that differ from the intended config defaults
    { username: username, password: password, enable: enable }.each do |key, val|
      row[key] = val if val && val != defaults[key]
    end
  end
  overrides += 1 if row[:username] || row[:password] || row[:enable]

  if nodes.where(name: name).update(row.merge(updated_at: Sequel.lit("datetime('now')"))).zero?
    nodes.insert(row)
  end
  imported += 1
end

puts "imported/updated #{imported} nodes into #{dst}"
puts "stored per-device credential overrides for #{overrides} nodes" if with_secrets || defaults.any?
skipped.each { |l| warn "SKIPPED (no name/model): #{l}" }

unless with_secrets
  puts defaults.any? ? "\nCredential sets found (only fields differing from the given defaults were stored):" : "\nCredential sets found (NOT imported - move these into the oxidized config):"
  creds.sort_by { |_, count| -count }.each do |(group, username, password, enable), count|
    puts format('  group=%-15s username=%-15s password=%-20s enable=%-15s (%d nodes)',
                group.inspect, username.inspect, password.inspect, enable.inspect, count)
  end
  puts <<~HINT

    If all nodes share one credential set, add to the oxidized config:
      username: <user>
      password: <pass>
      vars:
        enable: <enable-pass>
    Per-group sets go under:
      groups:
        <groupname>:
          username: <user>
          password: <pass>
          vars:
            enable: <enable-pass>
  HINT
end
