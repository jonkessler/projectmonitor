require 'fiber'

class UrlRetriever
  def initialize(url, options = {})
    # Options: { verify_ssl: BOOL, username: str, password: str}
    @options = options
    @url = url
    @callbacks = []
    @errbacks = []
  end

  def _run_in_reactor(&block)
    # EM already running.
    if EM.reactor_running?
      if block_given?
        Fiber.new { yield }.resume
      else
        Fiber.new { block.call }.resume
      end

    # EM not running.
    else
      if block_given?
        Fiber.new { EM.run(nil) { yield } }.resume
      else
        Fiber.new { EM.run(Proc.new { block.call }) }.resume
      end

    end
  end

  def _http
    # Event machine options object
    _options = {
      redirects: 5,
      connect_timeout: 30,
      inactivity_timeout: 30,
      ssl: { verify_peer: @options['verify_ssl'] },
      head: {'authorization' => [@options['username'], @options['password']]}
    }
    _options.delete_if { |key,value| !value.present? }
    @http_request = EM::HttpRequest.new uri.to_s, _options
  end

  def get
    _run_in_reactor { _http.get }
  end

  def poll(period)
    _run_in_reactor do
      EM.add_periodic_timer(period) do
        _http.get
      end
    end
  end

  def retrieve_content
    result = nil
    _run_in_reactor do
      req = _http.get
      req.callback { result = req.response; Fiber.yield }
      req.errback { throw "Error #{req.status}"; Fiber.yield }
    end
    return result
  end

  def _errback
    @errbacks.each { |block| block(@http_request) }
  end

  def _callback
    @callbacks.each { |block| block(@http_request) }
  end

  def errback(&block)
    @errbacks << block
  end

  def callback(&block)
    @callbacks << block
  end

  def stop
    @callbacks = {}
  end

  def uri
    if /\A\S+:\/\// === @url
      URI.parse @url
    else
      URI.parse "http://#{@url}"
    end
  end

  private :_run_in_reactor, :_http

end
