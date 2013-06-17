#
# Cookbook Name:: dev
# Recipe:: default
#
# Copyright 2011, OpenStreetMap Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "yaml"

include_recipe "apache"
include_recipe "git"
include_recipe "mysql"
include_recipe "postgresql"

package "php-apc"
package "php-db"
package "php-cgiwrap"
package "php-pear"

package "php5-cgi"
package "php5-cli"
package "php5-curl"
package "php5-fpm"
package "php5-imagick"
package "php5-mcrypt"
package "php5-mysql"
package "php5-pgsql"
package "php5-sqlite"

package "python"
package "python-argparse"
package "python-beautifulsoup"
package "python-cheetah"
package "python-dateutil"
package "python-magic"
package "python-psycopg2"

apache_module "expires"
apache_module "fastcgi-handler"
apache_module "rewrite"
apache_module "expires"
apache_module "wsgi"

apache_module "passenger" do
  conf "passenger.conf.erb"
end

munin_plugin "passenger_memory"
munin_plugin "passenger_processes"
munin_plugin "passenger_queues"
munin_plugin "passenger_requests"

gem_package "sqlite3"

gem_package "rails" do
  version "3.0.9"
end

service "php5-fpm" do
  action [ :enable, :start ]
  supports :status => true, :restart => true, :reload => true
end

template "/etc/php5/fpm/pool.d/default.conf" do
  source "fpm-default.conf.erb"
  owner "root"
  group "root"
  mode 0644
  notifies :reload, resources(:service => "php5-fpm")
end

file "/etc/php5/fpm/pool.d/www.conf" do
  action :delete
  notifies :reload, resources(:service => "php5-fpm")
end

package "phppgadmin"

template "/etc/phppgadmin/config.inc.php" do
  source "phppgadmin.conf.erb"
  owner "root"
  group "root"
  mode 0644
end

link "/etc/apache2/conf.d/phppgadmin" do
  action :delete
end

apache_site "phppgadmin.dev.openstreetmap.org" do
  template "apache.phppgadmin.erb"
end

node[:accounts][:users].each do |name,details|
  if ["user","administrator"].include?(details[:status])
    user_home = details[:home] || "#{node[:accounts][:home]}/#{name.to_s}"

    if File.directory?("#{user_home}/public_html")
      template "/etc/php5/fpm/pool.d/#{name}.conf" do
        source "fpm.conf.erb"
        owner "root"
        group "root"
        mode 0644
        variables :user => name
        notifies :reload, resources(:service => "php5-fpm")
      end

      apache_site "#{name}.dev.openstreetmap.org" do
        template "apache.user.erb"
        directory "#{user_home}/public_html"
        variables :user => name
      end
    end
  end
end

if node[:postgresql][:clusters]["9.1/main"]
  postgresql_user "apis" do
    cluster "9.1/main"
  end

  node[:dev][:rails].each do |name,details|
    database_name = details[:database] || "apis_#{name}"
    site_name = "#{name}.apis.dev.openstreetmap.org"
    site_aliases = details[:aliases] || []
    rails_directory = "/srv/#{name}.apis.dev.openstreetmap.org"

    postgresql_database database_name do
      cluster "9.1/main"
      owner "apis"
    end

    postgresql_extension "#{database_name}_btree_gist" do
      cluster "9.1/main"
      database database_name
      extension "btree_gist"
    end

    rails_port site_name do
      ruby node[:dev][:ruby]
      directory rails_directory
      user "apis"
      group "apis"
      repository details[:repository]
      revision details[:revision]
      database_port node[:postgresql][:clusters]["9.1/main"][:port]
      database_name database_name
      database_username "apis"
      run_migrations true
    end

    template "#{rails_directory}/config/initializers/setup.rb" do
      source "rails.setup.rb.erb"
      owner "apis"
      group "apis"
      mode 0644
      variables :site => site_name
      notifies :touch, resources(:file => "#{rails_directory}/tmp/restart.txt")
    end

    apache_site site_name do
      template "apache.rails.erb"
      variables :name => site_name, :aliases => site_aliases
    end
  end

  Dir.glob("/srv/*.apis.dev.openstreetmap.org").each do |rails_directory|
    name = File.basename(rails_directory, ".apis.dev.openstreetmap.org")

    unless node[:dev][:rails].include?(name)
      database_config = YAML.load_file("#{rails_directory}/config/database.yml")
      database_name = database_config["production"]["database"]
      site_name = "#{name}.apis.dev.openstreetmap.org"

      apache_site site_name do
        action [ :delete ]
      end

      directory rails_directory do
        action :delete
        recursive true
      end

      file "/etc/cron.daily/rails-#{name}" do
        action :delete
      end

      postgresql_database database_name do
        action :drop
        cluster "9.1/main"
      end
    end
  end

  directory "/srv/apis.dev.openstreetmap.org" do
    owner "apis"
    group "apis"
    mode 0755
  end

  template "/srv/apis.dev.openstreetmap.org/index.html" do
    source "apis.html.erb"
    owner "apis"
    group "apis"
    mode 0644
  end

  apache_site "apis.dev.openstreetmap.org" do
    template "apache.apis.erb"
  end

  node[:postgresql][:clusters].each do |name,details|
    postgresql_munin name do
      cluster name
      database "ALL"
    end
  end
end
