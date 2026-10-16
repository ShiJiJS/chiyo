#include "notification_queue.h"
#include <iostream>
#include <stdexcept>
#include <vector>

static void Check(bool condition) {
  if (!condition) throw std::runtime_error("notification delivery contract failed");
}

int main() {
  try {
    std::vector<std::string> sent;
    std::vector<std::pair<std::string, bool>> replies;
    NotificationQueue queue([&](const NotificationMessage& message) {
      sent.push_back(message.test ? "test" : message.request_id);
      return message.request_id != "fail";
    });
    const auto enqueue = [&](std::string id, bool test = false) {
      queue.Enqueue({id, test}, [&, id](bool accepted) { replies.emplace_back(id, accepted); });
    };
    enqueue("A"); enqueue("fail"); enqueue("B"); enqueue("", true); enqueue("C");
    Check(sent == std::vector<std::string>{"A"});
    Check(replies.size() == 1 && replies[0].second);
    queue.OnBalloonEvent(BalloonEvent::shown);
    Check(sent.size() == 1);
    auto clicked = queue.OnBalloonEvent(BalloonEvent::clicked);
    Check(clicked && clicked->request_id == "A");
    Check(sent == std::vector<std::string>({"A", "fail", "B"}));
    Check(replies.size() == 3 && !replies[1].second && replies[2].second);
    clicked = queue.OnBalloonEvent(BalloonEvent::clicked);
    Check(clicked && clicked->request_id == "B");
    Check(sent.back() == "test");
    clicked = queue.OnBalloonEvent(BalloonEvent::clicked);
    Check(clicked && clicked->test && clicked->request_id.empty());
    Check(sent.back() == "C");
    Check(!queue.OnBalloonEvent(BalloonEvent::timedOut));
    Check(!queue.OnBalloonEvent(BalloonEvent::clicked));
    enqueue("quiet"); enqueue("D");
    Check(!queue.OnBalloonEvent(BalloonEvent::hidden));
    clicked = queue.OnBalloonEvent(BalloonEvent::clicked);
    Check(clicked && clicked->request_id == "D");
    enqueue("E"); enqueue("F");
    queue.Reset();
    Check(replies.back() == std::make_pair(std::string("F"), false));
    Check(!queue.OnBalloonEvent(BalloonEvent::clicked));
    enqueue("G");
    clicked = queue.OnBalloonEvent(BalloonEvent::clicked);
    Check(clicked && clicked->request_id == "G");
    std::cout << "Native notification request/test queue contract passed.\n";
    return 0;
  } catch (const std::exception&) {
    std::cerr << "Native notification request/test queue contract failed.\n";
    return 1;
  }
}
