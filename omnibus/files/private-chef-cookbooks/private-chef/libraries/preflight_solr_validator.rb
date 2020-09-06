#
# Copyright:: 2015-2018 Chef Software, Inc.
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

require_relative './preflight_checks.rb'

class SolrPreflightValidator < PreflightValidator
  # The cs_*attr variables hold the user-defined configuration
  attr_reader :cs_solr_attr, :cs_erchef_attr, :cs_rabbitmq_attr
              :cs_elasticsearch_attr
              :cs_opscode_expander_attr

  # The node_*attr variables hold the default configuration
  attr_reader :node_solr_attr, :node_elasticsearch_attr, :node_erchef_attr

  def initialize(node)
    super

    @cs_solr_attr = PrivateChef['opscode_solr4']
    @cs_erchef_attr = PrivateChef['opscode_erchef']
    @cs_elasticsearch_attr = PrivateChef['elasticsearch']
    @cs_rabbitmq_attr = PrivateChef['rabbitmq']
    @cs_opscode_expander_attr = PrivateChef['opscode_expander']

    @node_erchef_attr = node['private_chef']['opscode-erchef']
    @node_solr_attr = node['private_chef']['opscode-solr4']
    @node_elasticsearch_attr = node['private_chef']['elasticsearch']
  end

  def run!
    verify_consistent_reindex_sleep_times

    verify_one_search_provider
    verify_es_disabled_if_user_set_external_solr
    verify_unused_services_are_disabled_if_using_internal_es

    warn_unchanged_external_flag
    warn_on_deprecated_solr
    warn_deprecated_indexing_change
    verify_external_url
    verify_erchef_config
  end

  def verify_consistent_reindex_sleep_times
    final_min = cs_erchef_attr['reindex_sleep_min_ms'] || node_erchef_attr['reindex_sleep_min_ms']
    final_max = cs_erchef_attr['reindex_sleep_max_ms'] || node_erchef_attr['reindex_sleep_max_ms']
    if final_min > final_max
      fail_with err_SOLR001_failed_validation(final_min, final_max)
    end
  end

  def verify_one_search_provider
    if elasticsearch_enabled? && solr_enabled?
      fail_with err_SOLR002_failed_validation
    end
  end

  # If an external search provider (ES or Solr) was explicitly enabled
  # by the user, then we expect that both internal search services
  # should be disabled.
  def verify_es_disabled_if_user_set_external_solr
    # NOTE(ssd) 2020-05-13: This might impact the people who we gave
    # pre-release access to.
    if cs_solr_attr['external'] && elasticsearch_enabled?
      fail_with err_SOLR003_failed_validation
    end

    if solr_enabled? && external?
      fail_with err_SOLR004_failed_validation
    end
  end

  # The user might have a combination of solr, rabbitmq or
  # opscode-expander explicitly enabled in their config.
  #
  # If we are using the new internal elasticsearch, this is an
  # unsupported configuration.
  #
  def verify_unused_services_are_disabled_if_using_internal_es
    if elasticsearch_enabled?
      msg = []
      if cs_solr_attr['enable']
        msg << err_SOLR005_failed_validation
      end

      if cs_rabbitmq_attr['enable']
        msg << err_SOLR006_failed_validation
      end

      if cs_opscode_expander_attr['enable']
        msg << err_SOLR007_failed_validation
      end
      unless msg.empty?
        fail_with msg.join("\n")
      end
    end
  end

  def external?
    if cs_solr_attr['external'].nil?
      node_solr_attr['external']
    else
      cs_solr_attr['external']
    end
  end

  def elasticsearch_enabled?
    # TODO(ssd) 2020-05-13: This currently lives in another PR, but to
    # facilitate updates for chef-backend users without a
    # configuration change, we are going to explicitly set
    # elasticsearch to disabled at runtime.
    return false if PrivateChef['use_chef_backend']

    if cs_elasticsearch_attr['enable'].nil?
      node_elasticsearch_attr['enable']
    else
      cs_elasticsearch_attr['enable']
    end
  end

  def solr_enabled?
    if cs_solr_attr['enable'].nil?
      node_solr_attr['enable']
    else
      cs_solr_attr['enable']
    end
  end

  def warn_unchanged_external_flag
    if OmnibusHelper.has_been_bootstrapped? && backend? && previous_run
      if cs_solr_attr.key?('external') && (cs_solr_attr['external'] != previous_run['opscode-solr4']['external'])
        ChefServer::Warnings.warn err_SOLR009_warn_validation
      end
    end
  end

  def warn_deprecated_indexing_change
    return if cs_solr_attr['external']
    return if !previous_run

    old_value = previous_run['deprecated_solr_indexing']
    new_value = PrivateChef['deprecated_solr_indexing']
    if old_value != new_value
      ChefServer::Warnings.warn err_SOLR014_warn_validation
    end
  end

  def verify_external_url
    if cs_solr_attr['external'] & !cs_solr_attr['external_url']
      fail_with err_SOLR010_failed_validation
    end
  end

  def verify_erchef_config
    provider = @cs_erchef_attr['search_provider']
    return true if provider.nil? # default provider

    case provider
    when 'elasticsearch'
      unless %w(batch inline).include?(@cs_erchef_attr['search_queue_mode'])
        fail_with err_SOLR011_failed_validation
      end
    when 'solr'
    else
      fail_with err_SOLR012_failed_validation
    end
  end

  def warn_on_deprecated_solr
    ChefServer::Warnings.warn err_SOLR013_warn_validation if PrivateChef['deprecated_solr_indexing']
  end

  def err_SOLR001_failed_validation(final_min, final_max)
    <<~EOM

      SOLR001: opscode_erchef['reindex_sleep_min_ms'] (#{final_min}) is greater than
               opscode_erchef['reindex_sleep_max_ms'] (#{final_max})

               The maximum sleep time should be greater or equal to the minimum sleep
               time.
    EOM
  end

  def err_SOLR002_failed_validation
    <<~EOM

      SOLR002: The #{CHEF_SERVER_NAME} is configured to enable both
               Elasticsearch and Solr. This is an unsupported configuration.

               Please update #{CHEF_SERVER_CONFIG_FILE} such that only one
               search provider is enabled.
      EOM
  end

  def err_SOLR003_failed_validation
    <<~EOM

      SOLR003: The #{CHEF_SERVER_NAME} is configured to use an external search
               index but the internal Elasticsearch is still enabled. This is
               an unsupported configuration.

               To disable the internal Elasticsearch, add the following to #{CHEF_SERVER_CONFIG_FILE}:

                   elasticsearch['enable'] = false

               To use the internal Elasticsearch, consider removing the configuration
               entry for opscode_solr4['external'].

     EOM
  end

  def err_SOLR004_failed_validation
    <<~EOM

      SOLR004: The #{CHEF_SERVER_NAME} is configured to use an external search
               provider but the internal Solr is still enabled. This is an
               unsupported configuration.

               To disable the internal Solr, add the following to #{CHEF_SERVER_CONFIG_FILE}:

                   opscode_solr4['enable'] = false

               Alternatively, if you are attempting to use the internal Solr,
               add the following to #{CHEF_SERVER_CONFIG_FILE}:

                   opscode_solr4['enable'] = true
                   opscode_solr4['external'] = false

    EOM
  end

  def err_SOLR005_failed_validation
    <<~EOM

      SOLR005: The #{CHEF_SERVER_NAME} is configured to use its internal
               Elasticsearch installation, but opscode_solr4 has been manually
               enabled. This is an unsupported configuration.

               Please update #{CHEF_SERVER_CONFIG_FILE} to ensure that
               opscode_solr4 is disabled:

                   opscode_solr4['enable'] = false

    EOM
  end

  def err_SOLR006_failed_validation
    <<~EOM

      SOLR006: The #{CHEF_SERVER_NAME} is configured to use its internal
               Elasticsearch installation, but RabbitMQ has been manually
               enabled. This is an unsupported configuration.

               Please update #{CHEF_SERVER_CONFIG_FILE} to ensure that
               rabbitmq is disabled:

                   rabbitmq['enable'] = false

    EOM
  end

  def err_SOLR007_failed_validation
    <<~EOM

      SOLR007: The #{CHEF_SERVER_NAME} is configured to use its internal
               Elasticsearch installation, but opscode-expander has been
               manually enabled. This is an unsupported configuration.

               Please update #{CHEF_SERVER_CONFIG_FILE} to ensure that
               opscode-expander is disabled:

                   opscode_expander['enable'] = false

    EOM
  end

  def err_SOLR009_warn_validation
    <<~EOM

       SOLR009: The value of opscode_solr4['external'] has been changed.  Search
                results against the new external search index may be incorrect. Please
                run `chef-server-ctl reindex --all` to ensure correct results

    EOM
  end

  def err_SOLR010_failed_validation
    <<~EOM

      SOLR010: No external url specified for Solr depsite opscode_solr4['external']
               being set to true. To use an external solr instance, please set
               opscode_solr4['external_url'] to the external solr endpoint.

    EOM
  end

  def err_SOLR011_failed_validation
    <<~EOM

      SOLR011: The elasticsearch provider is only supported by the batch or inline
               queue modes. To use the elasticsearch provider, please also set:

               opscode_erchef['search_queue_mode'] = 'batch'

               in #{CHEF_SERVER_CONFIG_FILE}

    EOM
  end

  def err_SOLR012_failed_validation
    <<~EOM
      SOLR012: The specified search provider (#{provider}) is not currently supported.
               Please choose from one of the following search providers:

               solr
               elasticsearch
    EOM
  end

  def err_SOLR013_warn_validation
    <<~EOM
      SOLR013: You have configured

                  deprecated_solr_indexing true

               Please note that solr indexing will be removed in a
               future Chef Server release.

               Please contact Chef Support for help moving to the
               Elasticsearch indexing pipeline.
    EOM
  end

  def err_SOLR014_warn_validation
    <<~EOM
       SOLR014: The value of deprecated_solr_indexing has been changed. Search
                results against the new search index may be incorrect. Please
                run `chef-server-ctl reindex --all` to ensure correct results.
    EOM
  end
end
