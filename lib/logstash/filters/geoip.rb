# encoding: utf-8
require "logstash/filters/base"
require "logstash/namespace"

require "logstash-filter-geoip_jars"

java_import "java.net.InetAddress"
java_import "com.maxmind.geoip2.DatabaseReader"
java_import "com.maxmind.geoip2.model.AnonymousIpResponse"
java_import "com.maxmind.geoip2.model.CityResponse"
java_import "com.maxmind.geoip2.model.ConnectionTypeResponse"
java_import "com.maxmind.geoip2.model.CountryResponse"
java_import "com.maxmind.geoip2.model.DomainResponse"
#java_import "com.maxmind.geoip2.model.EnterpriseResponse"
java_import "com.maxmind.geoip2.model.InsightsResponse"
java_import "com.maxmind.geoip2.model.IspResponse"
java_import "com.maxmind.db.CHMCache"

def suppress_all_warnings
  old_verbose = $VERBOSE
  begin
    $VERBOSE = nil
    yield if block_given?
  ensure
    # always re-set to old value, even if block raises an exception
    $VERBOSE = old_verbose
  end
end

# create a new instance of the Java class File without shadowing the Ruby version of the File class
module JavaIO
  include_package "java.io"
end


# The GeoIP filter adds information about the geographical location of IP addresses,
# based on data from the Maxmind GeoLite2 database.
#
# A `[geoip][location]` field is created if
# the GeoIP lookup returns a latitude and longitude. The field is stored in
# http://geojson.org/geojson-spec.html[GeoJSON] format. Additionally,
# the default Elasticsearch template provided with the
# <<plugins-outputs-elasticsearch,`elasticsearch` output>> maps
# the `[geoip][location]` field to an http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/mapping-geo-point-type.html#_mapping_options[Elasticsearch geo_point].
#
# As this field is a `geo_point` _and_ it is still valid GeoJSON, you get
# the awesomeness of Elasticsearch's geospatial query, facet and filter functions
# and the flexibility of having GeoJSON for all other applications (like Kibana's
# map visualization).
#
# Note: This product includes GeoLite2 data created by MaxMind, available from
# http://www.maxmind.com. This database is licensed under 
# http://creativecommons.org/licenses/by-sa/4.0/[Creative Commons Attribution-ShareAlike 4.0 International License]

class LogStash::Filters::GeoIP < LogStash::Filters::Base
  config_name "geoip"

  # The path to the GeoLite2 database file which Logstash should use. Only City database is supported by now.
  #
  # If not specified, this will default to the GeoLite2 City database that ships
  # with Logstash.
  config :database, :validate => :path

  # The field containing the IP address or hostname to map via geoip. If
  # this field is an array, only the first value will be used.
  config :source, :validate => :string, :required => true

  # An array of geoip fields to be included in the event.
  #
  # Possible fields depend on the database type. By default, all geoip fields
  # are included in the event.
  #
  # For the built-in GeoLite2 City database, the following are available:
  # `city_name`, `continent_code`, `country_code2`, `country_code3`, `country_name`,
  # `dma_code`, `ip`, `latitude`, `longitude`, `postal_code`, `region_name` and `timezone`.
  config :fields, :validate => :array, :default => []

  # Specify the field into which Logstash should store the geoip data.
  # This can be useful, for example, if you have `src_ip` and `dst_ip` fields and
  # would like the GeoIP information of both IPs.
  #
  # If you save the data to a target field other than `geoip` and want to use the
  # `geo_point` related functions in Elasticsearch, you need to alter the template
  # provided with the Elasticsearch output and configure the output to use the
  # new template.
  #
  # Even if you don't use the `geo_point` mapping, the `[target][location]` field
  # is still valid GeoJSON.
  config :target, :validate => :string, :default => 'geoip'

  # Specify the database type. By default "city" is selected (This is the type of the built-in GeoLite2 City database)
  config :dbtype, :validate => ['country', 'city', 'anonymousIp', 'connectionType', 'domain', 'enterprise', 'isp'  ], :default => 'city'

  # Should we merge the results into target. If set to false, we will override the value of the target field
  config :merge, :validate => :boolean, :default => true

  # GeoIP lookup is surprisingly expensive. This filter uses an cache to take advantage of the fact that
  # IPs agents are often found adjacent to one another in log files and rarely have a random distribution.
  # The higher you set this the more likely an item is to be in the cache and the faster this filter will run.
  # However, if you set this too high you can use more memory than desired.
  # Since the Geoip API upgraded to v2, there is not any eviction policy so far, if cache is full, no more record can be added.
  # Experiment with different values for this option to find the best performance for your dataset.
  #
  # This MUST be set to a value > 0. There is really no reason to not want this behavior, the overhead is minimal
  # and the speed gains are large.
  #
  # It is important to note that this config value is global to the geoip_type. That is to say all instances of the geoip filter
  # of the same geoip_type share the same cache. The last declared cache size will 'win'. The reason for this is that there would be no benefit
  # to having multiple caches for different instances at different points in the pipeline, that would just increase the
  # number of cache misses and waste memory.
  config :cache_size, :validate => :number, :default => 1000

  # GeoIP lookup is surprisingly expensive. This filter uses an LRU cache to take advantage of the fact that
  # IPs agents are often found adjacent to one another in log files and rarely have a random distribution.
  # The higher you set this the more likely an item is to be in the cache and the faster this filter will run.
  # However, if you set this too high you can use more memory than desired.
  #
  # Experiment with different values for this option to find the best performance for your dataset.
  #
  # This MUST be set to a value > 0. There is really no reason to not want this behavior, the overhead is minimal
  # and the speed gains are large.
  #
  # It is important to note that this config value is global to the geoip_type. That is to say all instances of the geoip filter
  # of the same geoip_type share the same cache. The last declared cache size will 'win'. The reason for this is that there would be no benefit
  # to having multiple caches for different instances at different points in the pipeline, that would just increase the
  # number of cache misses and waste memory.
  config :lru_cache_size, :validate => :number, :default => 1000
  
  # Tags the event on failure to look up geo information. This can be used in later analysis.
  config :tag_on_failure, :validate => :array, :default => ["_geoip_lookup_failure"]

  public
  def register
    suppress_all_warnings do
      if @database.nil?
        @database = ::Dir.glob(::File.join(::File.expand_path("../../../vendor/", ::File.dirname(__FILE__)),"GeoLite2-City.mmdb")).first

        if @database.nil? || !File.exists?(@database)
          raise "You must specify 'database => ...' in your geoip filter (I looked for '#{@database}')"
        end
      end

      @logger.info("Using geoip database", :path => @database)

      db_file = JavaIO::File.new(@database)
      begin
        @parser = DatabaseReader::Builder.new(db_file).withCache(CHMCache.new(@cache_size)).build();
      rescue Java::ComMaxmindDb::InvalidDatabaseException => e
        @logger.error("The GeoLite2 MMDB database provided is invalid or corrupted.", :exception => e, :field => @source)
        raise e
      end
    end
  end # def register

  public
  def filter(event)
    return unless filter?(event)

    begin
#      ip = event.respond_to? :get ? event.get(@source) : event[@source]
      ip = event[@source]
      ip = ip.first if ip.is_a? Array
      geo_data_hash = Hash.new
      ip_address = InetAddress.getByName(ip)
      response = @parser.send(@dbtype,ip_address)
      populate_geo_data(response, ip_address, geo_data_hash)
    rescue com.maxmind.geoip2.exception.AddressNotFoundException => e
      @logger.debug("IP not found!", :exception => e, :field => @source, :event => event)
    rescue java.net.UnknownHostException => e
      @logger.error("IP Field contained invalid IP address or hostname", :exception => e, :field => @source, :event => event)
    rescue Exception => e
      @logger.error("Unknown error while looking up GeoIP data", :exception => e, :field => @source, :event => event)
      # Dont' swallow this, bubble up for unknown issue
      raise e
    end
    if @merge
      event[@target] ||= {}
      event[@target].merge!(geo_data_hash)
    else
      event[@target] = geo_data_hash
    end
    logger.info "GEOTARGET: #{event[@target].inspect}"

    if geo_data_hash.empty?
      tag_unsuccessful_lookup(event)
      return
    end

    filter_matched(event)
  end # def filter

  def populate_geo_data(response, ip_address, geo_data_hash)
    case @dbtype
      when "city"
        country = response.getCountry()
        subdivision = response.getMostSpecificSubdivision()
        city = response.getCity()
        postal = response.getPostal()
        location = response.getLocation()

        # if location is empty, there is no point populating geo data
        # and most likely all other fields are empty as well
        if location.getLatitude().nil? && location.getLongitude().nil?
          return
        end
        geo_data_hash["city_name"] = city.getName()
        geo_data_hash["country_name"] = country.getName()
        geo_data_hash["continent_code"] = response.getContinent().getCode()
        geo_data_hash["continent_name"] = response.getContinent().getName()
        geo_data_hash["country_code2"] = country.getIsoCode()
        geo_data_hash["country_code3"] = country.getIsoCode()
        geo_data_hash["ip"] = ip_address.getHostAddress()
        geo_data_hash["postal_code"] = postal.getCode()
        geo_data_hash["dma_code"] = location.getMetroCode()
        geo_data_hash["region_name"] = subdivision.getName()
        geo_data_hash["region_code"] = subdivision.getIsoCode()
        geo_data_hash["timezone"] = location.getTimeZone()
        geo_data_hash["location"] = [ location.getLongitude(), location.getLatitude() ]
        geo_data_hash["latitude"] = location.getLatitude()
        geo_data_hash["longitude"] = location.getLongitude()
      else
        geo_data_hash.merge!(JSON.parse(response.toJson()))
    end
    geo_data_hash.reject! {|key, value| !@fields.include? key} unless @fields.empty?
    logger.info "GEODATA: #{geo_data_hash.inspect}"
  end

  def tag_unsuccessful_lookup(event)
    @logger.debug? && @logger.debug("IP #{event.get(@source)} was not found in the database", :event => event)
    @tag_on_failure.each{|tag| event.tag(tag)}
  end

end # class LogStash::Filters::GeoIP
