require "uri"
require "securerandom"
require "cfoundry"
require "httparty"

class RegularUser
  def self.from_env
    new(*%w(NYET_TARGET NYET_REGULAR_USERNAME NYET_REGULAR_PASSWORD).map do |var|
      ENV[var] || raise(ArgumentError, "missing #{var}")
    end)
  end

  def initialize(target, username, password)
    @target = URI(target)
    @username = username
    @password = password
  end

  attr_reader :client

  def user
    debug(:find, client.current_user)
  end

  def find_organization_by_name(name)
    debug(:find, client.organization_by_name(name).tap do |org|
      raise "failed to find organization '#{name}'" unless org
    end)
  end

  def create_space(org)
    debug(:create, client.space.tap do |space|
      space.name = "nyet-space-#{SecureRandom.uuid}"
      space.organization = org
      space.developers = [client.current_user]
      space.create!
    end)
  end

  def create_app(space, name, environment={})
    debug(:create, client.app.tap do |app|
      app.name = name
      app.memory = 512
      app.total_instances = 1
      app.space = space
      app.env = environment
      app.create!
    end)
  end

  def list_apps()
    debug(:app_list, client.apps)
  end

  def create_managed_service_instance(space, service_label, plan_name, instance_name)
    service_plan = find_service_plan(service_label, plan_name)
    if service_plan.nil?
      raise ArgumentError, "no such a service plan #{plan_name} for label #{service_label}"
    end
    debug(:create, client.managed_service_instance.tap do |service_instance|
      service_instance.name = instance_name
      service_instance.service_plan = service_plan
      service_instance.space = space
      service_instance.create!
    end)
  end

  def create_user_provided_service_instance(space, instance_name, credentials)
    debug(:create, client.user_provided_service_instance.tap do |service_instance|
      service_instance.credentials = credentials
      service_instance.name = instance_name
      service_instance.space = space
      service_instance.create!
    end)
  end

  def clean_up_app_from_previous_run(name)
    if app = client.app_by_name(name)
      debug(:delete, app)
      app.delete!(recursive: true)
    end
  end

  def clean_up_service_instance_from_previous_run(space, name)
    if service_instance = space.service_instance_by_name(name)
      debug(:delete, service_instance)
      begin
        service_instance.delete!(recursive: true)
      rescue CFoundry::ServerError => e
        raise e unless e.message =~ /Subscription already deleted/
        debug(:delete, "Tried to delete service instance #{service_instance.guid}, but it has already been removed from the cloud controller")
      end
    end
  end

  def create_route(app, host, domain_name=nil)
    space = app.space

    if domain_name
      raise "Failed to find domain with '#{domain_name}' in #{space.inspect}" \
        unless domain = space.domain_by_name(domain_name)
    else
      domain = space.domains.first
    end

    debug(:create, client.route.tap do |route|
      route.host = host
      route.domain = domain
      route.space = space
      route.create!
      app.add_route(route)
    end)
  end

  def clean_up_route_from_previous_run(host)
    if route = client.route_by_host(host)
      debug(:delete, route)
      route.delete!(recursive: true)
    end
  end

  def find_service_plan(service_label, plan_name)
    debug(:find_service_plan, find_service(service_label).service_plans.detect { |p| p.name == plan_name } || raise("No plan named #{plan_name.inspect}"))
  end

  def bind_service_to_app(service_instance, app)
    CFoundry::V2::ServiceBinding.module_eval do
      attribute :credentials, :hash
    end

    binding = client.service_binding
    binding.service_instance = service_instance
    binding.app = app
    binding.create!

    debug(:create_binding, binding)
    debug(:credentials, binding.credentials)

    binding
  end

  def find_service_instance(guid)
    client.service_instances.detect {|instance| instance.guid == guid }
  end

  def clean_up_orphaned_appdirect_service_instances(space, instance_name)
    debug(:delete, "any orphaned service instances in space #{space.guid}")
    base_uri = ENV['ORPHAN_FINDER_DOMAIN_NAME']
    auth = {:username => ENV['ORPHAN_FINDER_USERNAME'], :password => ENV['ORPHAN_FINDER_PASSWORD']}
    delete_orphans_url = base_uri +
      "/api/organizations/#{space.organization.guid}/spaces/#{space.guid}/appdirect_orphans/#{instance_name}"
    response = HTTParty.delete(delete_orphans_url, { :basic_auth => auth})

    debug(:delete, delete_orphans_url)
    debug(:response, response.inspect)
  end

  private

  def debug(action, object)
    puts "--- #{action}: #{object.inspect} (regular user: #{client.current_user.inspect})"
    object
  end

  def client
    @client ||= CFoundry::V2::Client.new(@target.to_s).tap do |c|
      c.login(username: @username, password: @password)
      c.trace = true if ENV['NYET_TRACE']
    end
  end

  def find_service(service_label)
    client.services.detect { |s| s.label == service_label } or raise "No service named #{service_label.inspect}"
  end
end
