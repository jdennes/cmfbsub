require "helper"

set :environment, :test
OmniAuth.config.test_mode = true

describe "The Campaign Monitor Subscribe Form app" do
  let(:app) { Sinatra::Application }
  let(:user_id) { "7654321" }
  let(:fb_token) { "xxxx" }
  let(:cm_api_key) { "testapikey" }

  describe "GET /auth/facebook/callback?code=xyz" do
    let(:auth_hash) {
      {
        "provider" => "facebook",
        "uid" => user_id,
        "info" => {},
        "credentials" => {
          "token" => fb_token,
          "expires_at" => "1321747205",
          "expires" => "true"
        },
        "extra" => {}
      }
    }

    before do
      OmniAuth.config.mock_auth[:facebook] = OmniAuth::AuthHash.new(auth_hash)
    end

    it "stores the correct session values and redirects" do
      get "/auth/facebook/callback"

      expect(last_request.env["rack.session"]["fb_auth"]["uid"]).to eq(user_id)
      expect(last_request.env["rack.session"]["fb_token"]).to eq (fb_token)
      expect(last_response.status).to eq(302)
      expect(last_response.location).to eq("http://example.org/")
    end
  end

  describe "GET /" do
    context "when there's no session for the user" do
      it "redirects to request authorisation" do
        get "/"

        expect(last_request.env["rack.session"]["fb_auth"]).to be_nil
        expect(last_request.env["rack.session"]["fb_token"]).to be_nil
        expect(last_response.status).to eq(302)
        expect(last_response.location).to eq("http://example.org/auth/facebook")
      end
    end

    context "when there's a session for the user but it doesn't match the current fb user" do
      it "clears the session and redirects to request authorisation" do
        get "/",
          { "facebook" => { "user_id" => user_id } },
          { "rack.session" => { "fb_auth" => { "uid" => "1234567" } } }

        expect(last_request.env["rack.session"]["fb_auth"]).to be_nil
        expect(last_request.env["rack.session"]["fb_token"]).to be_nil
        expect(last_response.status).to eq(302)
        expect(last_response.location).to eq("http://example.org/auth/facebook")
      end
    end

    context "when the user is successfully authenticated but hasn't authed with Campaign Monitor" do
      before do
        stub_request(:get, "https://graph.facebook.com/v2.2/me?access_token=xxxx").
          to_return(:status => 200, :body => "")
      end

      it "loads the main page, requesting that the user sign into Campaign Monitor" do
        get "/",
          { "facebook" => { "user_id" => user_id } },
          { "rack.session" => { "fb_auth" => { "uid" => user_id }, "fb_token" => fb_token } }

        expect(last_request.env["rack.session"]["fb_auth"]).to eq({ "uid" => user_id })
        expect(last_request.env["rack.session"]["fb_token"]).to eq (fb_token)
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Log into your account")
      end
    end
  end

  describe "GET /clients/:api_key" do
    context "when a call to the Campaign Monitor API succeeds" do
      before do
        stub_request(:get, "https://testapikey:x@api.createsend.com/api/v3/clients.json").
          to_return(
            :status => 200,
            :body => "[{\"ClientID\":\"clientid\",\"Name\":\"client name\"}]",
            :headers => { "Content-Type" => "application/json;charset=utf-8" })
      end

      it "gets the clients for the account matching the api key" do
        get "/clients/#{cm_api_key}"

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to eq("application/json;charset=utf-8")
        expect(last_response.body).to eq("[{\"ClientID\":\"clientid\",\"Name\":\"client name\"}]")
      end
    end

    context "when a call to the Campaign Monitor API fails" do
      before do
        stub_request(:get, "https://testapikey:x@api.createsend.com/api/v3/clients.json").
          to_return(
            :status => 500,
            :body => "[{\"Code\":\"500\",\"Message\":\"Sorry.\"}]",
            :headers => { "Content-Type" => "application/json;charset=utf-8" })
      end

      it "gets an empty list" do
        get "/clients/#{cm_api_key}"

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to eq("application/json;charset=utf-8")
        expect(last_response.body).to eq("[]")
      end
    end
  end

  describe "GET /lists/:api_key/:client_id" do
    let(:client_id) { "43242343" }
    context "when a call to the Campaign Monitor API succeeds" do
      before do
        stub_request(:get, "https://testapikey:x@api.createsend.com/api/v3/clients/#{client_id}/lists.json").
          to_return(
            :status => 200,
            :body => "[{\"ListID\":\"listid\",\"Name\":\"list name\"}]",
            :headers => { "Content-Type" => "application/json;charset=utf-8" })
      end

      it "gets the subscriber lists for the client" do
        get "/lists/#{cm_api_key}/#{client_id}"

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to eq("application/json;charset=utf-8")
        expect(last_response.body).to eq("[{\"ListID\":\"listid\",\"Name\":\"list name\"}]")
      end
    end

    context "when a call to the Campaign Monitor API fails" do
      before do
        stub_request(:get, "https://testapikey:x@api.createsend.com/api/v3/clients/#{client_id}/lists.json").
          to_return(
            :status => 500,
            :body => "[{\"Code\":\"500\",\"Message\":\"Sorry.\"}]",
            :headers => { "Content-Type" => "application/json;charset=utf-8" })
      end

      it "gets an empty list" do
        get "/lists/#{cm_api_key}/#{client_id}"

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to eq("application/json;charset=utf-8")
        expect(last_response.body).to eq("[]")
      end
    end
  end

  describe "GET /ondeauth" do
    it "deletes any accounts associated with the fb user and responds with 200 OK" do
      get "/ondeauth", { "facebook" => { "user_id" => user_id } }

      accounts = Account.all(:user_id => user_id)
      expect(accounts).to eq([])
      expect(last_response.status).to eq(200)
    end
  end

  describe "GET /auth/failure" do
    it "clears the session and redirects to /" do
      get "/auth/failure"

      expect(last_request.env["rack.session"]["fb_auth"]).to be_nil
      expect(last_request.env["rack.session"]["fb_token"]).to be_nil
      expect(last_response.status).to eq(302)
      expect(last_response.location).to eq("http://example.org/")
    end
  end

  describe "GET /logout" do
    it "clears the session and redirects to /" do
      get "/logout"

      expect(last_request.env["rack.session"]["fb_auth"]).to be_nil
      expect(last_request.env["rack.session"]["fb_token"]).to be_nil
      expect(last_response.status).to eq(302)
      expect(last_response.location).to eq("http://example.org/")
    end
  end

  describe "GET /privacy" do
    it "shows the privacy page" do
      get "/privacy"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to \
        include("The Campaign Monitor Subscribe Form app respect's the privacy of people who use it")
    end
  end

  describe "GET /nothingtoseehere" do
    it "shows the app's 404 Not Found page" do
      get "/nothingtoseehere"
      expect(last_response.status).to eq(404)
      expect(last_response.body).to \
        include("We don't recognise that as part of Campaign Monitor Subscribe Form - sorry!")
    end
  end

  describe "GET /boom" do
    it "shows the app's 500 Server Error page" do
      expect do
        get "/boom"
        expect(last_response.status).to eq(500)
        expect(last_response.body).to \
          include("We're really sorry that there's something wrong with Campaign Monitor Subscribe Form")
      end.to raise_error
    end
  end

end
