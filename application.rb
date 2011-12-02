require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require './environment'
require 'omniauth/oauth'
require 'mogli'
require 'createsend'

configure do
  require 'newrelic_rpm' if production?
  config = YAML.load_file('config.yaml') if !production?
  APP_ID = production? ? ENV['APP_ID'] : config['APP_ID']
  APP_API_KEY = production? ? ENV['APP_API_KEY'] : config['APP_API_KEY']
  APP_SECRET = production? ? ENV['APP_SECRET'] : config['APP_SECRET']
  APP_CANVAS_NAME = production? ? ENV['APP_CANVAS_NAME'] : config['APP_CANVAS_NAME']

  set :views, "#{File.dirname(__FILE__)}/views"
  enable :sessions
  DataMapper.setup(:default, (ENV["DATABASE_URL"] || "sqlite3:///#{File.expand_path(File.dirname(__FILE__))}/#{Sinatra::Base.environment}.db"))

  use Rack::Facebook, { :secret => APP_SECRET }
  use OmniAuth::Builder do
    client_options = production? ? {:ssl => {:ca_path => "/etc/ssl/certs"}} : {}
    provider :facebook, APP_ID, APP_SECRET, {:iframe => true, :client_options => client_options, :scope => 'manage_pages,offline_access'}
  end
  OmniAuth.config.full_host = "https://apps.facebook.com/#{APP_CANVAS_NAME}"

  disable :protection
end

helpers do
  def versioned_stylesheet(style)
    "/#{style}.css?" + File.mtime(File.join(settings.public_folder, "scss", "#{style}.scss")).to_i.to_s
  end

  def versioned_javascript(js)
    "/js/#{js}.js?" + File.mtime(File.join(settings.public_folder, "js", "#{js}.js")).to_i.to_s
  end

  def white_label
    return (APP_CANVAS_NAME =~ /createsend$/ ? true : false)
  end

  def att_friendly_key(key)
    "cf-#{key[1..-2]}"
  end

  def partial(name, locals={})
    haml "_#{name}".to_sym, :layout => false, :locals => locals
  end

  def check_auth
    redirect '/auth/facebook' if session['fb_auth'].nil?
    # If we don't have the right user in the session, clear the session
    if !session['fb_auth'].nil? and !params['facebook'].nil? and 
      session['fb_auth']['uid'] != params['facebook']['user_id']
      clear_session
      redirect '/auth/facebook'
    end
  end

end

before do
  content_type :html, :charset => 'utf-8'
  @js_conf = { :appId => APP_ID, :canvasName => APP_CANVAS_NAME,
    :userIdOnServer => session['fb_token'] ? session['fb_auth']['uid'] : nil}.to_json
end

error do
  haml :error
end

not_found do
  haml :not_found
end

def get_user(user_id)
  session['fb_token'] ? Mogli::User.find(user_id, Mogli::Client.new(session['fb_token'])) : nil
end

def get_page(page_id)
  Mogli::Page.find(page_id, Mogli::Client.new(session['fb_token']))
end

def get_form_by_page_id(page_id)
  Form.first(:page_id => page_id)
end

def get_api_key(site_url, username, password)
  @result = nil
  begin
    cs = CreateSend::CreateSend.new
    @result = cs.apikey site_url, username, password
    rescue Exception => e
      p "Error: #{e}"
      @result = nil
  end
  @result
end

def get_clients(api_key)
  @result = []
  begin
    CreateSend.api_key api_key
    cs = CreateSend::CreateSend.new
    @result = cs.clients
    rescue Exception => e
      p "Error: #{e}"
      @result = []
  end
  @result
end

def get_lists_for_client(api_key, client_id)
  @result = []
  begin
    CreateSend.api_key api_key
    @result = CreateSend::Client.new(client_id).lists
    rescue Exception => e
      p "Error: #{e}"
      @result = []
  end
  @result
end

def get_custom_fields_for_list(api_key, list_id)
  @result = []
  begin
    CreateSend.api_key api_key
    @result = CreateSend::List.new(list_id).custom_fields
    rescue Exception => e
      p "Error: #{e}"
      @result = []
  end
  @result
end

def get_saved_forms(account)
  @saved_forms = {} # To be indexed by page id
  @form_fields = {} # To be indexed by form id
  if account
    account.forms.each do |f|
      @saved_forms[f.page_id] = f
      @form_fields[f.id] = f.custom_fields
    end
  end
  { :forms => @saved_forms, :fields => @form_fields }
end

get '/' do
  check_auth

  @user = get_user("me")
  @pages = @user ? @user.accounts : []
  @account = @user ? Account.first(:user_id => @user.id) : nil
  @clients = @account ? get_clients(@account.api_key) : []
  @saved_forms = get_saved_forms(@account)
  @js_data = @account ? {
    :account => {:api_key => @account.api_key, :user_id => @user.id,
      :clients => @clients, :saved_forms => @saved_forms}}.to_json : ''
  haml :settings, :layout => false
end

get '/saved/:page_id/?' do |page_id|
  @page = get_page(page_id)
  @next_url = @page.has_added_app ? @page.link :
    "http://www.facebook.com/add.php?api_key=#{APP_API_KEY}&pages=1&page=#{@page.id}"

  haml :settings_saved, :layout => false
end

post '/apikey/?' do
  content_type 'application/json', :charset => 'utf-8'
  result = get_api_key(params['site_url'], params['username'], params['password'])
  @user = get_user("me")
  if !result.nil? && @user
    @account = Account.first_or_create({:api_key => result.ApiKey, :user_id => @user.id})
    @clients = @account ? get_clients(@account.api_key) : []
    [200, {:account => {
      :api_key => @account.api_key, :user_id => @user.id,
        :clients => @clients}}.to_json]
  else
    [400, {:message => "Error geting API key..."}.to_json]
  end
end

get '/clients/:api_key/?' do |api_key|
  content_type 'application/json', :charset => 'utf-8'
  [200, get_clients(api_key).to_json]
end

get '/lists/:api_key/:client_id/?' do |api_key, client_id|
  content_type 'application/json', :charset => 'utf-8'
  [200, get_lists_for_client(api_key, client_id).to_json]
end

get '/customfields/:api_key/:list_id/?' do |api_key, list_id|
  content_type 'application/json', :charset => 'utf-8'
  [200, get_custom_fields_for_list(api_key, list_id).to_json]
end

def find_cm_custom_field(input, key)
  input.each do |cf|
    return cf if cf.Key == key
  end
  nil
end

post '/page/:page_id/?' do |page_id|
  check_auth
  content_type 'application/json', :charset => 'utf-8'

  @user = get_user("me")
  @account = Account.first(:api_key => params[:api_key], :user_id => @user.id)
  @sf = @account.forms.first(:page_id => page_id)
  @page = get_page(page_id)
  if @sf
    @sf.list_id = params[:list_id]
    @sf.client_id = params[:client_id]
    @sf.intro_message = params[:intro_message].strip
    @sf.thanks_message = params[:thanks_message].strip
  else
    @sf = Form.new(
      :account => @account, :page_id => page_id, :client_id => params[:client_id], :list_id => params[:list_id],
      :intro_message => params[:intro_message].strip, :thanks_message => params[:thanks_message].strip)
  end

  if @sf.valid?
    begin
      @custom_fields = get_custom_fields_for_list(@account.api_key, @sf.list_id)
      @sf.custom_fields.all.destroy if @sf.custom_fields.length > 0
      params.each do |i, v|
        if i.start_with? "cf-"
          # Surrounding square brackets are deliberately stripped in field ID
          # see settings.haml. e.g. Field with key "[field]" has param id "cf-field".
          cmcf = find_cm_custom_field(@custom_fields, "[#{i[3..-1]}]")
          if cmcf
            cf = CustomField.new(
              :name => cmcf.FieldName, :field_key => cmcf.Key,
              :data_type => cmcf.DataType,
              :field_options => cmcf.FieldOptions * "^")
            @sf.custom_fields << cf
          end
        end
      end
      @sf.save
      message = "Thanks, you successfully saved your subscribe form for #{@page.name}."
      return [200, { :status => "success", :message => message}.to_json]
      rescue CreateSend::CreateSendError, CreateSend::ClientError, 
        CreateSend::ServerError, CreateSend::Unavailable => cse
        p "Error: #{cse}"
        # TODO: Be more helpful with errors...
        return [200, { :status => "failure", 
          :message => "Sorry, something went wrong while saving your subscribe form for #{@page.name}. Please try again."}.to_json]
    end
  end
end

get '/tab/?' do
  @page_id = params['facebook'] ? params['facebook']['page']['id'] : ''
  @sf = get_form_by_page_id(@page_id)
  if @sf
    @fields = @sf.custom_fields.all(:order => [:name.asc])
  end
  @js_data = { :page_id => @page_id}.to_json
  haml :subscribe_form, :layout => false
end

post '/subscribe/:page_id/?' do |page_id|
  content_type 'application/json', :charset => 'utf-8'

  @sf = get_form_by_page_id(page_id)
  begin
    CreateSend.api_key @sf.account.api_key
    @page_id = page_id
    @fields = @sf.custom_fields.all(:order => [:name.asc])

    custom_fields = []
    params.each do |i, v|
      if i.start_with? "cf-"
        key = "[#{i[3..-1]}]"
        if v.kind_of?(Array)
          # Dealing with a multi-option-select-many
          v.each do |o|
            custom_fields << { :Key => key, :Value => o }
          end
        else
          custom_fields << { :Key => key, :Value => v }
        end
      end
    end
    CreateSend::Subscriber.add @sf.list_id, params[:email].strip, params[:name].strip,
      custom_fields, true
    return [200, {:status => "success", :message => @sf.thanks_message}.to_json]

    rescue Exception => e
      p "Error: #{e}" # TODO: Be more helpful with errors...
      return [200, {:status => "error", 
        :message => "Sorry, there was a problem subscribing you to our list. Please try again."}.to_json]
  end
end

get '/ondeauth/?' do
  fb = params['facebook']
  if fb && fb['user_id']
    @accounts = Account.all(:user_id => fb['user_id'])
    @accounts.destroy if @accounts
  end
  [200]
end

get '/auth/facebook/callback/?' do
  session['fb_auth'] = request.env['omniauth.auth']
  session['fb_token'] = session['fb_auth']['credentials']['token']
  session['fb_error'] = nil
  redirect '/'
end

get '/auth/failure/?' do
  clear_session
  session['fb_error'] = 'To use this application you must permit access to your basic information.'
  redirect '/'
end

get '/logout/?' do
  clear_session
  redirect '/'
end

def clear_session
  session['fb_auth'] = nil
  session['fb_token'] = nil
  session['fb_error'] = nil
end

%w(reset cm fb).each do |style|
  get "/#{style}.css" do
    content_type :css, :charset => 'utf-8'
    path = "public/scss/#{style}.scss"
    last_modified File.mtime(path)
    scss File.read(path)
  end
end