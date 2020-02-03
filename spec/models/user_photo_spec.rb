# frozen_string_literal: true
describe UserPhoto do

  describe 'reindex' do
    it 'indexes and reindexes' do
      user = Fabricate(:user)
      ActiveRecord::Base.record_timestamps = false

        2.times{|i| user.user_photos.create(created_at: DateTime.now, updated_at: DateTime.now) }
        UserPhoto.reindex(user)
        expect(UserPhoto.where(user_id: user.id).pluck(:id)).to eq([1,2])
        photo = user.user_photos.second
        photo.order_index= 0
        photo.updated_at = DateTime.now + 200.years
        photo.save

        ActiveRecord::Base.record_timestamps = true
        UserPhoto.reindex(user)
        user.user_photos.reload
        expect(user.user_photos.pluck(:id)).to eq([2,1])

    end
  end

  it 'does not save if the user is underage' do
    user = Fabricate(:user, dob: Time.now - 13.years)
    photo = UserPhoto.create(user_id: user.id)
    expect(photo.id).to eq(nil)
  end

end
