require 'rails_helper'

RSpec.describe GuessGame, type: :model do
  describe 'db columns' do
    it { expect(subject).to have_db_column :id }
    it { expect(subject).to have_db_column :about_user_id }
    it { expect(subject).to have_db_column :by_user_id }
    it { expect(subject).to have_db_column :user_message_id }
    it { expect(subject).to have_db_column :have_all_answers }
  end

  context "relationships" do
    it { expect(subject).to have_many(:answers) }
    it { expect(subject).to belong_to(:by_user) }
    it { expect(subject).to belong_to(:about_user) }
  end
end
