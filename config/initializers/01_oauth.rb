Anathief::SETTINGS = YAML.load(File.read("#{Rails.root}/config/settings.yml"))["#{Rails.env}"]

module Facebook
  APP_ID = Anathief::SETTINGS['facebook']['app_id']
  SECRET = Anathief::SETTINGS['facebook']['app_secret']
  CANVAS_URL = Anathief::SETTINGS['facebook']['canvas_url']
end

Anathief::REDIS_KPREFIX = Anathief::SETTINGS['redis']['kprefix']

unless MiniFB.method_defined?(:signed_request_params)
  puts "Monkey patching MiniFB"
  module MiniFB
      def self.signed_request_params(secret, req)
          s, p = req.split(".")
          p = base64_url_decode(p)
          h = JSON.parse(p)
          h.delete('algorithm') if h['algorithm'] == 'HMAC-SHA256'
          h
      end
  end
end