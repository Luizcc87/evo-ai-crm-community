# frozen_string_literal: true

class Api::V1::EvolutionGo::ProxyController < Api::V1::BaseController
  include EvolutionGoConcern

  before_action :set_instance_params

  # GET /api/v1/evolution_go/proxy
  # Returns proxy health status for the instance (no credentials exposed)
  def show
    if @api_url.blank? || @instance_token.blank? || @instance_uuid.blank?
      return render json: { error: 'Missing required parameters: api_url, instance_token, instance_uuid' }, status: :bad_request
    end

    begin
      health = get_proxy_status(@api_url, @instance_token)
      render json: { success: true, data: health }
    rescue Net::OpenTimeout, Net::ReadTimeout
      render json: { success: false, error: 'Evolution Go indisponível', detail: 'Timeout ao conectar' }, status: :service_unavailable
    rescue StandardError => e
      Rails.logger.error "Evolution Go Proxy: get status error: #{e.message}"
      render json: { success: false, error: e.message }, status: :service_unavailable
    end
  end

  # POST /api/v1/evolution_go/proxy
  # Set or update proxy configuration on Evolution Go instance
  def update
    if @api_url.blank? || @admin_token.blank? || @instance_uuid.blank?
      return render json: { error: 'Missing required parameters: api_url, admin_token, instance_uuid' }, status: :bad_request
    end

    proxy_params = params.require(:proxy).permit(:protocol, :host, :port, :username, :password)

    if proxy_params[:host].blank?
      return render json: { error: 'host is required' }, status: :bad_request
    end

    if proxy_params[:port].blank?
      return render json: { error: 'port is required' }, status: :bad_request
    end

    begin
      result = set_proxy(@api_url, @admin_token, @instance_uuid, proxy_params.to_h)
      render json: { success: true, data: result }
    rescue Net::OpenTimeout, Net::ReadTimeout
      render json: { success: false, error: 'Evolution Go indisponível', detail: 'Timeout ao conectar' }, status: :service_unavailable
    rescue StandardError => e
      Rails.logger.error "Evolution Go Proxy: set proxy error: #{e.message}"
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/evolution_go/proxy
  # Remove proxy configuration from Evolution Go instance
  def destroy
    if @api_url.blank? || @admin_token.blank? || @instance_uuid.blank?
      return render json: { error: 'Missing required parameters: api_url, admin_token, instance_uuid' }, status: :bad_request
    end

    begin
      delete_proxy(@api_url, @admin_token, @instance_uuid)
      render json: { success: true, message: 'Proxy removido com sucesso' }
    rescue Net::OpenTimeout, Net::ReadTimeout
      render json: { success: false, error: 'Evolution Go indisponível', detail: 'Timeout ao conectar' }, status: :service_unavailable
    rescue StandardError => e
      Rails.logger.error "Evolution Go Proxy: delete proxy error: #{e.message}"
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def set_instance_params
    @instance_uuid = params[:instance_uuid] || params[:instanceId] || params[:id]

    whatsapp_channel = Channel::Whatsapp.joins(:inbox)
                                        .where(provider: 'evolution_go')
                                        .where('provider_config @> ?', { instance_uuid: @instance_uuid }.to_json)
                                        .first

    if whatsapp_channel
      creds = evolution_go_credentials_for(whatsapp_channel)
      @inbox = whatsapp_channel.inbox
      @api_url = creds[:api_url]
      @admin_token = creds[:admin_token]
      @instance_token = creds[:instance_token]
    else
      @api_url = params[:api_url].presence || GlobalConfigService.load('EVOLUTION_GO_API_URL', '').to_s.strip
      @admin_token = params[:admin_token].presence || GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', '').to_s.strip
      @instance_token = params[:instance_token]
    end
  end

  def get_proxy_status(api_url, instance_token)
    uri = URI.parse("#{api_url.chomp('/')}/instance/proxy/status")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 5
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go Proxy: status #{response.code}"

    raise "Evolution Go respondeu #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    # Retorna apenas os campos seguros — nunca expõe username/password
    raw = body['data'] || body
    {
      instanceId: raw['instanceId'],
      proxyAddress: raw['proxyAddress'],
      status: raw['status'] || 'inactive',
      lastCheck: raw['lastCheck'],
      latencyMs: raw['latencyMs'],
      error: raw['error'],
      thresholdMs: raw['thresholdMs']
    }
  rescue JSON::ParserError
    raise 'Resposta inválida do Evolution Go'
  end

  def set_proxy(api_url, admin_token, instance_uuid, proxy)
    uri = URI.parse("#{api_url.chomp('/')}/instance/proxy/#{instance_uuid}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = admin_token
    request['Content-Type'] = 'application/json'
    request.body = {
      protocol: proxy['protocol'].presence,
      host: proxy['host'],
      port: proxy['port'].to_s,
      username: proxy['username'].presence,
      password: proxy['password'].presence
    }.compact.to_json

    response = http.request(request)
    Rails.logger.info "Evolution Go Proxy: set proxy #{response.code}"

    raise "Falha ao configurar proxy. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    raw = body['data'] || body
    # Strip auth data from response — never return username/password
    raw.except('username', 'password')
  rescue JSON::ParserError
    raise 'Resposta inválida do Evolution Go'
  end

  def delete_proxy(api_url, admin_token, instance_uuid)
    uri = URI.parse("#{api_url.chomp('/')}/instance/proxy/#{instance_uuid}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 15

    request = Net::HTTP::Delete.new(uri)
    request['apikey'] = admin_token
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go Proxy: delete proxy #{response.code}"

    raise "Falha ao remover proxy. Status: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  end
end
