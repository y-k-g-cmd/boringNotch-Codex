var policy = QuotaFailurePolicy()
precondition(!policy.result(success: false, connected: false, enabled: true))
precondition(!policy.result(success: false, connected: true, enabled: false))
precondition(policy.result(success: false, connected: true, enabled: true))
for _ in 0..<10 { precondition(!policy.result(success: false, connected: true, enabled: true)) }
precondition(!policy.result(success: true, connected: true, enabled: true))
precondition(policy.result(success: false, connected: true, enabled: true))
print("PASS: quota warning connected-only, opt-out, one-per-episode and recovery rearm")
