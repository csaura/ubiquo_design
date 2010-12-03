class Block < ActiveRecord::Base
  validates_presence_of :block_type, :page

  has_many :block_uses, :class_name => 'Block', :foreign_key => 'shared_id'
  belongs_to :shared, :class_name => 'Block', :foreign_key => 'shared_id'
  has_many :widgets, :dependent => :destroy, :order => 'widgets.position ASC'
  belongs_to :page
  after_save :update_page
  after_destroy :update_page
  
  # Given a page and block_type, create and return a block
  def self.create_for_block_type_and_page(block_type, page, options = {})
    options.reverse_merge!({:block_type => block_type, :page_id => page.id})
    self.create(options)
  end

  def is_used_by_other_blocks?
    self.block_uses.present?
  end

  def available_shared_blocks
    Block.all(:conditions => ["blocks.is_shared = ? AND blocks.block_type = ? AND " +
                              "(pages.published_id IS NOT NULL OR pages.is_modified = ?)",
                              true, self.block_type, true],
              :include => [:page])
  end

  def real_block
    self.shared_id ? self.shared : self
  end

#  def available_widgets
#    Ubiquodesign::structure.get(:block => block_type)[:widgets].keys
#  end
 
  private

  # When a block is saved, the associated page must change its modified attribute 
  def update_page
    block_page = self.page.reload
    block_page.update_modified(true) unless block_page.is_modified?
  end
end
