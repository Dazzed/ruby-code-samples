class GuessGameQuestion < ActiveRecord::Base
  attr_accessible :text, :hidden, :my_text

  validates :text, :presence => true
  validates :my_text, :presence => true

  has_many :choices, class_name: 'GuessGameChoice', inverse_of: :question, dependent: :destroy

  def serializable_hash(options = {})
    result = super(options)

    result['text'] = self.replace_w_name(options[:name])

    result.delete('my_text')
    result.delete('created_at')
    result.delete('updated_at')
    result.delete('hidden')
    result
  end

  def replace_w_name(name=nil)
    if name.nil?
      return self.my_text
    else
      return self.text.gsub(/(%@)/, name)
    end

    return self.text
  end

end
