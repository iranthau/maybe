class Family::AutoCategorizer
  Error = Class.new(StandardError)

  # Only send debt/asset-relevant categories to the LLM (no budget categories like Entertainment, Food & Drink, etc.)
  DEBT_AND_ASSET_KEYWORDS = %w[loan payment fee interest debt].freeze

  def initialize(family, transaction_ids: [])
    @family = family
    @transaction_ids = transaction_ids
  end

  def auto_categorize
    raise Error, "No LLM provider for auto-categorization" unless llm_provider

    if scope.none?
      Rails.logger.info("No transactions to auto-categorize for family #{family.id}")
      return
    else
      Rails.logger.info("Auto-categorizing #{scope.count} transactions for family #{family.id}")
    end

    result = llm_provider.auto_categorize(
      transactions: transactions_input,
      user_categories: user_categories_input
    )

    unless result.success?
      Rails.logger.error("Failed to auto-categorize transactions for family #{family.id}: #{result.error.message}")
      return
    end

    scope.each do |transaction|
      auto_categorization = result.data.find { |c| c.transaction_id == transaction.id }

      category_id = user_categories_input.find { |c| c[:name] == auto_categorization&.category_name }&.dig(:id)

      if category_id.present?
        transaction.enrich_attribute(
          :category_id,
          category_id,
          source: "ai"
        )
      end

      transaction.lock_attr!(:category_id)
    end
  end

  private
    attr_reader :family, :transaction_ids

    # For now, OpenAI only, but this should work with any LLM concept provider
    def llm_provider
      Provider::Registry.get_provider(:openai)
    end

    def user_categories_input
      debt_and_asset_categories.map do |category|
        {
          id: category.id,
          name: category.name,
          is_subcategory: category.subcategory?,
          parent_id: category.parent_id,
          classification: category.classification
        }
      end
    end

    def debt_and_asset_categories
      categories = family.categories.to_a
      categories.select do |category|
        debt_or_asset_category?(category, categories)
      end
    end

    def debt_or_asset_category?(category, all_categories)
      return true if category.classification == "income"
      return true if category.classification == "expense" && debt_or_asset_expense?(category.name)
      return false unless category.parent_id.present?

      parent = all_categories.find { |c| c.id == category.parent_id }
      parent.present? && debt_or_asset_category?(parent, all_categories)
    end

    def debt_or_asset_expense?(name)
      downcased = name.downcase
      DEBT_AND_ASSET_KEYWORDS.any? { |keyword| downcased.include?(keyword) }
    end

    def transactions_input
      scope.map do |transaction|
        {
          id: transaction.id,
          amount: transaction.entry.amount.abs,
          classification: transaction.entry.classification,
          description: transaction.entry.name,
          merchant: transaction.merchant&.name
        }
      end
    end

    def scope
      family.transactions.where(id: transaction_ids, category_id: nil)
                         .enrichable(:category_id)
                         .includes(:category, :merchant, :entry)
    end
end
