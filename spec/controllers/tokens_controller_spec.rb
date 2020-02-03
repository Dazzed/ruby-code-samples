# frozen_string_literal: true

describe TokensController, type: :controller do
  describe 'POST /tokens/external_auth' do
    let(:token) {
      {
        access_token: '123',
        provider: 'facebook'
      }
    }
    let(:snapchat_token) {
      {
        provider: 'snapchat',
        provider_id: '123'
      }
    }

    describe 'Facebook auth failed' do
      it 'returns 401 if raised APIError' do
        allow_any_instance_of(Koala::Facebook::API).to receive(:get_object).and_raise(Koala::Facebook::APIError.new(400, 'mock response'))
        post :external_auth, { token: token }
        expect(response.status).to eq 401
        expect(response.body).to eq({ error: 'Facebook API access failed.', message: 'Facebook API access failed.' }.to_json)
      end

      it 'returns 401 if just returned empty results' do
        allow_any_instance_of(Koala::Facebook::API).to receive(:get_object).and_return({})
        post :external_auth, { token: token }
        expect(response.status).to eq 401
        expect(response.body).to eq({ error: 'Facebook API access failed.', message: 'Facebook API access failed.' }.to_json)
      end

      it 'returns 401 if just returned nil' do
        allow_any_instance_of(Koala::Facebook::API).to receive(:get_object).and_return(nil)
        post :external_auth, { token: token }
        expect(response.status).to eq 401
        expect(response.body).to eq({ error: 'Facebook API access failed.', message: 'Facebook API access failed.' }.to_json)
      end
    end

    describe 'Facebook auth underage' do
      let(:user) { Fabricate.build(:user) } # only :build the User object, not saved via :create so that we can test it is saved
      let(:fb_id) { '123456' }
      let(:successful_underage_auth) {
        OpenStruct.new(
          first_name: user.first_name,
          last_name: user.last_name,
          email: user.email,
          gender: user.gender,
          birthday: (Time.now-13.years).strftime('%m/%d/%Y')
        )
      }

      before(:each) do
        allow(User).to receive(:fb_id_for).and_return(fb_id)
        allow_any_instance_of(Koala::Facebook::API).to receive(:get_object).and_return(successful_underage_auth)
        # SNS notifications are still concurrent with User registration...
        allow_any_instance_of(Aws::SNS::Client).to receive(:publish).and_return(true)
      end

      it 'returns an error but creates a hidden/banned user' do
        post :external_auth, { token: token }
        expect(response.status).to eq 401
        expect(JSON.parse(response.body)["message"]).to eq "You must be at least 18 years old to use Friended."
        expect(User.last.ban_reason).to eq "You must be at least 18 years old to use Friended."
        expect(User.last.hidden_reason).to eq "You must be at least 18 years old to use Friended."
      end
    end

    describe 'Facebook auth succeeded' do
      let(:user) { Fabricate.build(:user) } # only :build the User object, not saved via :create so that we can test it is saved
      let(:fb_id) { '123456' }
      let(:successful_auth) {
        OpenStruct.new(
          first_name: user.first_name,
          last_name: user.last_name,
          email: user.email,
          gender: user.gender,
          birthday: user.dob.strftime('%m/%d/%Y')
        )
      }

      before(:each) do
        allow(User).to receive(:fb_id_for).and_return(fb_id)
        allow_any_instance_of(Koala::Facebook::API).to receive(:get_object).and_return(successful_auth)
        # SNS notifications are still concurrent with User registration...
        allow_any_instance_of(Aws::SNS::Client).to receive(:publish).and_return(true)
      end

      it 'creates a User' do
        post :external_auth, { token: token }
        expect(response.status).to eq 200
        created = User.last
        expect(created.first_name).to eq user.first_name
        expect(created.email).to eq user.email
      end

      describe 'with A/B testing' do
        let(:inactive_cohort) { Fabricate(:cohort, active: false) }
        let(:cohort) { Fabricate(:cohort, active: true) }
        let(:enable_cohort_flag) { true }

        before(:each) do
          enable_cohort_flag = CONFIG[:enable_cohorts]
        end

        after(:each) do
          CONFIG[:enable_cohorts] = enable_cohort_flag
        end

        it 'assigns a Cohort if config enabled' do
          cohort # create it before testing begins
          CONFIG[:enable_cohorts] = true
          post :external_auth, { token: token }
          expect(response.status).to eq 200
          created = User.last
          expect(created.user_settings.cohort.id).to eq cohort.id
        end

        it 'does not assign a Cohort if config enabled but no active Cohort' do
          inactive_cohort # create it before testing begins
          CONFIG[:enable_cohorts] = true
          post :external_auth, { token: token }
          expect(response.status).to eq 200
          created = User.last
          expect(created.user_settings.cohort).to eq nil
        end

        it 'does not assign a Cohort if config disabled' do
          cohort # create it before testing begins
          CONFIG[:enable_cohorts] = false
          post :external_auth, { token: token }
          expect(response.status).to eq 200
          created = User.last
          expect(created.user_settings.cohort).to eq nil
        end

        describe 'using split gem' do
          let(:cohort1) { Fabricate(:cohort, active: true) }
          let(:cohort2) { Fabricate(:cohort, active: true) }

          before(:each) do
            CONFIG[:enable_cohorts] = true
            cohort1 # create it before testing begins
            cohort2 # create it before testing begins
          end

          2.times do |index|
            it "assigns an available Cohort option #{index}" do
              cohorts = [cohort1, cohort2]
              post :external_auth, { token: token }
              expect(response.status).to eq 200
              created = User.last
              expect(cohorts).to include(created.user_settings.cohort)
            end
          end
        end

        describe 'split gem - block randomization algorithm' do
          before(:each) do
            CONFIG[:enable_cohorts] = true
          end

          it 'matches round-robin over time' do
            10.times{ |i| Fabricate(:cohort, active: true) }
            30.times do |i|
              u = Fabricate.build(:user)
              fb_id = SecureRandom.hex.to_s
              auth = OpenStruct.new(
                first_name: u.first_name,
                last_name: u.last_name,
                email: u.email,
                gender: u.gender,
                id: fb_id,
                birthday: u.dob.strftime('%m/%d/%Y')
              )
              allow(User).to receive(:fb_id_for).and_return(fb_id)
              allow_any_instance_of(Koala::Facebook::API).to receive(:get_object).and_return(auth)
              post :external_auth, { token: token }
            end
            expect(UserSetting.group(:cohort_id).count.values).to eq [1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3] # the 1 nil is for the initial User created manually for spec suite up top
          end
        end

        describe 'using manually provided Cohort during registration' do
          before(:each) do
            CONFIG[:enable_cohorts] = true
          end

          it 'assigns specific Cohort by name if it\'s active' do
            custom_cohort = Fabricate(:cohort, name: 'custom', active: true)
            post :external_auth, { token: token, cohort_name: custom_cohort.name }
            expect(response.status).to eq 200
            created = User.last
            expect(created.user_settings.cohort.id).to eq custom_cohort.id
          end

          it 'assigns specific Cohort by name if it\'s inactive' do
            custom_cohort = Fabricate(:cohort, name: 'custom', active: false)
            post :external_auth, { token: token, cohort_name: custom_cohort.name }
            expect(response.status).to eq 200
            created = User.last
            expect(created.user_settings.cohort.id).to eq custom_cohort.id
          end
        end
      end
    end
    describe 'Snapchat Login' do
      it 'creates a snapchat user' do
        post :external_auth, { token: snapchat_token }
        expect(response.status).to eq 200
      end
    end
  end

  describe 'User Login /users/' do
    let(:new_user) { Fabricate(:user) }

    it 'login user' do
      post :login, { email: new_user.email, password: "foobaz123"}
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)["user"]["first_name"]).to eq(new_user.first_name)
    end
  end

end