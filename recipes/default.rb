#
# Cookbook Name:: spout
# Recipe:: default
#
# Copyright 2014, YOUR_COMPANY_NAME
#
# All rights reserved - Do Not Redistribute
#
#

include_recipe "rabbitmq"
include_recipe "database::postgresql"

app_config = data_bag_item('apps', node['deploy']['data_bag'])
app_home = "#{node['deploy']['deploy_to']}/current"
app_root = "#{app_home}/#{node['deploy']['app_name']}"

applet_name = node['deploy']['applet_name']
postgres_connection = {:host => 'localhost', :username => "postgres"}

rabbitmq_user node['rabbitmq']['user'] do
    password node['rabbitmq']['password']
    action :add
end

def create_nginx_template(release_path)
    Chef::Log.info("Hitting nginx function with #{release_path}")
    template "/etc/nginx/sites-available/default" do
        source "nginx-default.erb"
        owner "root"
        group "root"
        variables(
            :app_name => node['deploy']['app_name'],
            :app_home => release_path,
            :staticfiles_root => node['deploy']['staticfiles_root'],
            :socket_path => "/tmp/spout.sock",
            :domain => node['deploy']['domain']
        )
    end
end


celery_options = { "broker" => "amqp://#{node['rabbitmq']['user']}@localhost" }
celeryd_options = { 
    "broker" => "amqp://#{node['rabbitmq']['user']}@localhost",
    "concurrency" => 10,
    "queues" => "celery"
}

postgresql_database app_config['database']['name'] do
    connection postgres_connection
    #owner node['deploy']['user']
    action :create
end

postgresql_database_user app_config['database']['username'] do
    password app_config['database']['password']
    connection postgres_connection
    action :create
end

directory "/var/log/celery" do
    owner node['deploy']['user']
    group node['deploy']['user']
    mode "0755"
end

supervisor_service "celeryd-#{node['deploy']['app']['name']}" do
    command "#{node['deploy']['deploy_to']}/shared/env/bin/celery worker -A #{node['deploy']['celery_app']}"
    user node['deploy']['user']
    autorestart true
    autostart true
    stdout_logfile "/var/log/celery/celeryd-#{node['deploy']['app']['name']}.log"
    stderr_logfile "/var/log/celery/celeryd-#{node['deploy']['app']['name']}.log"
    priority 998
    directory "#{node['deploy']['deploy_to']}/current/"
    environment(
        :DJANGO_SETTINGS_MODULE => "#{node['deploy']['applet_name']}.settings" 
    )
    action :enable
end
    

application node['deploy']['app']['name'] do
    path node['deploy']['deploy_to']
    owner node['user']
    group node['group']
    repository node['deploy']['repository']
    revision node['deploy']['branch']
    migrate true
    before_deploy do
        template "/etc/nginx/sites-available/default" do
            source "nginx-default.erb"
            owner "root"
            group "root"
            variables(
                :app_name => node['deploy']['app_name'],
                :environment_path => "#{node['deploy']['deploy_to']}/shared/env",
                :staticfiles_root => "#{release_path}/#{node['deploy']['staticfiles_root']}",
                :socket_path => "/tmp/spout.sock",
                :domain => node['deploy']['domain']
            )
        end
    end
    after_restart do
        Chef::Resource::Notification.new("supervisor_service[celeryd-#{node['deploy']['app']['name']}]", :start)
    end

    django do
        requirements "requirements.pip"
        settings_template "local_settings.py.erb"
        debug true
        
        database do
            database "spout"
            engine "postgresql_psycopg2"
            username app_config['database']['username']
            password app_config['database']['password']
        end
    end

    gunicorn do
        socket_path "/tmp/spout.sock"
        app_module :django
        port 8080
    end
end

