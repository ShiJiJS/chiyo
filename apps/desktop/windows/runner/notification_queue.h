#ifndef RUNNER_NOTIFICATION_QUEUE_H_
#define RUNNER_NOTIFICATION_QUEUE_H_

#include <deque>
#include <functional>
#include <optional>
#include <string>
#include <utility>

struct NotificationMessage {
  std::string request_id;
  bool test = false;
};

enum class BalloonEvent { shown, hidden, timedOut, clicked };

// Public native delivery adapter. The Shell sees only one outstanding balloon,
// so an old click can never acquire the ID of a later queued request/test.
class NotificationQueue {
 public:
  using Sender = std::function<bool(const NotificationMessage&)>;
  using Reply = std::function<void(bool)>;
  explicit NotificationQueue(Sender sender) : sender_(std::move(sender)) {}

  void Enqueue(NotificationMessage message, Reply reply) {
    if (pending_.size() >= 64) { reply(false); return; }
    pending_.push_back({std::move(message), std::move(reply)});
    Pump();
  }

  std::optional<NotificationMessage> OnBalloonEvent(BalloonEvent event) {
    if (event == BalloonEvent::shown || !active_) return std::nullopt;
    auto ended = std::move(active_);
    active_.reset();
    Pump();
    return event == BalloonEvent::clicked ? ended : std::nullopt;
  }

  void Reset() {
    active_.reset();
    auto discarded = std::move(pending_);
    pending_.clear();
    for (auto& entry : discarded) entry.reply(false);
  }

 private:
  struct Pending { NotificationMessage message; Reply reply; };
  void Pump() {
    if (pumping_) return;
    pumping_ = true;
    while (!active_ && !pending_.empty()) {
      auto entry = std::move(pending_.front());
      pending_.pop_front();
      active_ = entry.message;
      const bool accepted = sender_(entry.message);
      if (!accepted) active_.reset();
      entry.reply(accepted);
    }
    pumping_ = false;
  }
  Sender sender_;
  std::deque<Pending> pending_;
  std::optional<NotificationMessage> active_;
  bool pumping_ = false;
};

#endif  // RUNNER_NOTIFICATION_QUEUE_H_
