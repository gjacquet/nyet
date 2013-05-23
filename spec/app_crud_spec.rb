require 'timeout'
require 'spec_helper'
require 'nyet_helpers'

Bundler.require(:default)

describe 'App CRUD' do
  include NyetHelpers

  let(:client) { logged_in_client }
  let(:app_name) { 'crud' }

  let(:org_name) do
    org || "org-#{SecureRandom.uuid}"
  end

  let(:space_name) do
    "space-#{SecureRandom.uuid}"
  end

  around do |example|
    clean_up_previous_run(client, app_name)
    with_org(org_name) do
      space = client.space
      space.name = space_name
      space.organization = client.organization_by_name(org_name)
      with_model(space) do
        space.add_developer client.current_user if org
        example.run
      end
    end

    expect(client.organization_by_name(org_name)).to(be_nil) unless org
    expect(client.space_by_name(space_name)).to be_nil
  end

  it 'can CRUD' do
    extend AppCrud
    with_timer(:create) { create }
    with_timer(:read) { read }
    with_timer(:update) { update }
    with_timer(:delete) { delete }
  end

  module AppCrud
    attr_accessor :app, :route
    CHECK_DELAY = 0.5.freeze
    CHECK_TIMEOUT = 120.freeze

    def create
      @app = client.app
      app.name = app_name
      app.memory = 256
      app.total_instances = 1
      org = client.organization_by_name(org_name)
      app.space = org.space_by_name(space_name)
      app.create!

      @route = client.route
      route.host = app_name
      route.domain = app.space.domains.first
      route.space = app.space

      route.create!

      app.add_route(route)

      app.upload(app_path('ruby', 'simple'))

      app.start!(true)

      Timeout::timeout(CHECK_TIMEOUT) do
        begin
          until app.instances.first.state == 'RUNNING'
            sleep CHECK_DELAY
          end
        rescue CFoundry::APIError => e
          if e.error_code == 170002 # app not yet staged
            sleep CHECK_DELAY
            retry
          end

          raise
        end
      end
    end

    def read
      expect(HTTParty.get("http://#{route.host}.#{route.domain.name}").body).to eq('hi')
    end

    def update
      #update the app by scaling instances to two
      app.total_instances = 2
      app.update!
      Timeout::timeout(90) do
        until app.total_instances == 2 &&
              app.instances.map(&:state).uniq == ['RUNNING']
          sleep CHECK_DELAY
        end
      end
    end

    def delete
      app.delete!
      Timeout::timeout(30) do
        while HTTParty.get("http://#{route.host}.#{route.domain.name}").success?
          sleep CHECK_DELAY
        end
      end
      route.delete!
    end
  end
end