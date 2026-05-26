class Assistant::Function::GetAccounts < Assistant::Function
  class << self
    def name
      "get_accounts"
    end

    def description
      "Use this to see what accounts the user has along with their current and historical balances. For debts (loans, credit cards), includes interest rate, APR, term, minimum payment, and other details."
    end
  end

  def call(params = {})
    {
      as_of_date: Date.current,
      accounts: family.accounts.visible.includes(:balances, :accountable).map do |account|
        base = {
          name: account.name,
          balance: account.balance,
          currency: account.currency,
          balance_formatted: account.balance_money.format,
          classification: account.classification,
          type: account.accountable_type,
          start_date: account.start_date,
          is_plaid_linked: account.plaid_account_id.present?,
          status: account.status,
          historical_balances: historical_balances(account)
        }
        debt = debt_details(account)
        base[:debt_details] = debt if debt.present?
        base
      end
    }
  end

  private
    def debt_details(account)
      return nil unless account.liability?

      case account.accountable
      when ::Loan
        loan = account.loan
        details = {}
        details[:interest_rate_percent] = loan.interest_rate&.round(2)&.to_s if loan.interest_rate.present?
        details[:rate_type] = loan.rate_type if loan.rate_type.present?
        details[:term_months] = loan.term_months if loan.term_months.present?
        details[:original_balance_formatted] = loan.original_balance.format
        details[:monthly_payment_formatted] = loan.monthly_payment&.format if loan.monthly_payment.present?
        details
      when ::CreditCard
        cc = account.credit_card
        details = {}
        details[:apr_percent] = cc.apr&.round(2)&.to_s if cc.apr.present?
        details[:minimum_payment_formatted] = cc.minimum_payment_money&.format if cc.minimum_payment.present?
        details[:available_credit_formatted] = cc.available_credit_money&.format if cc.available_credit.present?
        details[:annual_fee_formatted] = cc.annual_fee_money&.format if cc.annual_fee.present?
        details[:credit_utilization] = credit_utilization(account) if cc.available_credit.present? && cc.available_credit.positive?
        details
      else
        nil
      end
    end

    def credit_utilization(account)
      cc = account.credit_card
      return nil unless cc.available_credit.present? && cc.available_credit.positive?

      pct = (account.balance.to_d / cc.available_credit * 100).round(1)
      "#{pct}%"
    end

    def historical_balances(account)
      start_date = [ account.start_date, 5.years.ago.to_date ].max
      period = Period.custom(start_date: start_date, end_date: Date.current)
      balance_series = account.balance_series(period: period, interval: "1 month")

      to_ai_time_series(balance_series)
    end
end
