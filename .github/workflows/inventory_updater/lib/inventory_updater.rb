# frozen_string_literal: true

require 'yaml'

require_relative 'inventory_updater/analogue/pocket_service'
require_relative 'inventory_updater/github/github_service'
require_relative 'inventory_updater/jekyll/jekyll_service'
require_relative 'inventory_updater/jekyll/post'
require_relative 'inventory_updater/cache_service'
require_relative 'inventory_updater/repository_parser'
require_relative 'inventory_updater/repository_service'

class InventoryUpdater
  ASSETS_DIRECTORY = 'assets'
  AUTHORS_DIRECTORY = 'authors'
  DATA_DIRECTORY = '_data'
  IMAGES_DIRECTORY = 'images'
  PLATFORMS_DIRECTORY = 'platforms'

  REPOSITORIES_FILE = 'repositories.yml'
  CORES_FILE = 'cores.yml'

  POST_TYPE_NEW = 'new'
  POST_TYPE_UPDATE = 'update'

  HEADER = <<~TXT
    # ##############################################################################
    # #                                                                            #
    # #                        THIS FILE IS AUTO-GENERATED                         #
    # #                           DO NOT EDIT THIS FILE                            #
    # #               ADD NEW CORE REPOSITORIES TO REPOSISTORIES.YML               #
    # #                                                                            #
    # ##############################################################################
  TXT

  attr_reader :github_service, :repository_service, :cache_service, :jekyll_service

  def initialize
    @github_service = GitHub::GitHubService.new
    @repository_service = RepositoryService.new
    @cache_service = CacheService.new
    @jekyll_service = Jekyll::JekyllService.new
  end

  def update_cores
    puts 'Updating Analogue Pocket cores'

    owner_cores = []

    # Parse the repositories and group them by owner
    owner_repositories = get_repositories.group_by { |repository| repository.owner }

    # Process the repositories
    owner_repositories.each do |owner, repositories|
      cores = []
      repositories.each do |repository|
        repository_cores = process_repository(repository)
        cores.concat(repository_cores)
      end

      owner_cores << { "username" => owner, "cores" => cores.sort_by { |core| core['id'] } }
    end

    # Update the cores.yml file
    cores_path = File.join(DATA_DIRECTORY, CORES_FILE)
    File.open(cores_path, "wb") do |file|
      file << HEADER
      file << owner_cores.to_yaml
    end

    puts 'Completed updating Analogue Pocket cores'
  end

  private

  def get_repositories
    repositories_path = File.join(DATA_DIRECTORY, REPOSITORIES_FILE)
    return RepositoryParser.parse(repositories_path)
  end

  def process_repository(repository)
    puts "Processing repository: #{repository.display_name}"
    # Download / extract the core to temporary folder
    root_path = @repository_service.download_core(repository)

    serialized_cores = []

    begin
      download_url = nil
      funding = nil
      latest_release = nil
      sponsor_only = false

      # Initialize the service responsible for interacting with the core folder
      pocket_service = Analogue::PocketService.new(root_path)

      # Process the individual cores
      cores = pocket_service.get_cores
      cores.each do |core|
        core_id = core.id
        cached_version = @cache_service.get_version(core_id)

        if core.version == cached_version
          serialized_cores << @cache_service.get_core(core_id)
          next
        end

        platform_id = core.platform_id
        platform = pocket_service.get_platform(platform_id)

        download_url ||= @repository_service.get_download_url(repository)

        github_repository = repository.github_repository
        funding ||= @github_service.funding(github_repository)
        latest_release ||= @github_service.latest_release(github_repository, repository.prerelease) if repository.release?
        sponsor_only = sponsor_check(core)

        # Update the author icon
        icon_file = "#{core_id}.png"
        icon_path = File.join(ASSETS_DIRECTORY, IMAGES_DIRECTORY, AUTHORS_DIRECTORY, icon_file)
        pocket_service.export_icon(core_id, icon_path)

        # Update the platform image
        image_file = "#{platform_id}.png"
        image_path = File.join(ASSETS_DIRECTORY, IMAGES_DIRECTORY, PLATFORMS_DIRECTORY, image_file)
        pocket_service.export_image(platform_id, image_path)

        # Create post
        post_type = cached_version.nil? ? POST_TYPE_NEW : POST_TYPE_UPDATE
        post_content = pocket_service.get_info(core_id)
        create_post(core, post_type, post_content)

        serialized_cores << serialize_core(repository, core, platform, download_url, latest_release, funding, sponsor_only)
      end
    ensure
      # Delete the temporary directory
      FileUtils.remove_entry root_path
    end

    return serialized_cores
  end

  def sponsor_check(core)
    #add custom checks as needed i guess
    if core.author == "jotego"
      return core.data.data_slots.any?{|data_slot| data_slot.name == "JTBETA"}
    end

    return false
  end

  def serialize_core(repository, core, platform, download_url, latest_release, funding, sponsor_only)
    return {
      'id' => core.id,
      'display_name' => repository.display_name,
      'repository' => {
        'platform' => 'github',
        'name' => repository.name,
        'prerelease' => repository.prerelease
      },
      'sponsor_only' => sponsor_only,
      'download_url' => download_url,
      'platform_id' => core.platform_id,
      'description' => core.description,
      'version' => core.version,
      'date_release' => core.date_release,
      'platform' => {
        'category' => platform.metadata.category,
        'name' => platform.metadata.name,
        'manufacturer' => platform.metadata.manufacturer,
        'year' => platform.metadata.year
      }
    }.tap do |hash|
        hash['repository']['tag_name'] = latest_release.tag_name unless latest_release.nil?

        data_slots = core.data.data_slots.select {|data_slot| data_slot.required}
        hash['assets'] = data_slots.map do |data_slot|
          { 'platform' => core.platform_id }.tap do |asset|
            asset['filename'] = data_slot.filename if data_slot.filename
            asset['extensions'] = data_slot.extensions if data_slot.extensions
            asset['core_specific'] = data_slot.configuration.core_sepecific_file if data_slot.configuration.core_sepecific_file
          end
        end

        hash['sponsor'] = {}.tap do |sponsor|
          sponsor['community_bridge'] = funding.community_bridge if funding.community_bridge
          sponsor['github'] = funding.github if funding.github
          sponsor['issuehunt'] = funding.issuehunt if funding.issuehunt
          sponsor['ko_fi'] = funding.ko_fi if funding.ko_fi
          sponsor['liberapay'] = funding.liberapay if funding.liberapay
          sponsor['open_collective'] = funding.open_collective if funding.open_collective
          sponsor['otechie'] = funding.otechie if funding.otechie
          sponsor['patreon'] = funding.patreon if funding.patreon
          sponsor['tidelift'] = funding.tidelift if funding.tidelift
          sponsor['custom'] = funding.custom if funding.custom
        end unless funding.nil?
      end
  end

  def create_post(core, type, content)
    author = core.author
    shortname = core.shortname

    case type
    when POST_TYPE_NEW
      title = "#{author} has released #{shortname}"
    when POST_TYPE_UPDATE
      version = core.version
      title = "#{shortname} by #{author} has been updated to #{version}"
    end

    date = Time.now
    categories = [author, shortname]
    tags = [type]

    post = Jekyll::Post.new(title, date, categories, tags, content)

    jekyll_service.create_post(shortname, post)
  end
end

if __FILE__ == $0
  inventory_updater = InventoryUpdater.new
  inventory_updater.update_cores
end
