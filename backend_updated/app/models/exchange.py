"""
Exchange Request / Exchange Proposal models.

These add an EXPLICIT negotiation workflow on top of the existing passive
matching system (BarterPreference + BarterMatch in app/models/barter.py).
The two systems are complementary, not competing:

  BarterPreference/BarterMatch — category-level "radar": declares "I offer
  category X, need category Y" and passively surfaces detected matches as
  notifications. No accept/reject; a user can appear in many matches at
  once with no commitment.

  ExchangeRequest/ExchangeProposal (this file) — the actual transaction:
  ties a request to a SPECIFIC service the user is offering (not just a
  category), lets another user send a concrete proposal (their own
  specific service in return), and the request's owner explicitly
  accepts or rejects it. This is the "اطلب/اقترح/وافق" (request/propose/
  approve) flow.

ExchangeRequest.offered_category_id is a deliberate denormalization of
offered_service.category_id, copied once at creation time. This isn't
duplication for its own sake — it's what lets the direct-matching
algorithm (app/algorithms/direct_match.py) do a plain O(n) hash-map pass
over plain attributes without a join for every comparison.
"""
import enum
from typing import TYPE_CHECKING, List, Optional

from sqlalchemy import Boolean, Enum as SAEnum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.category import ServiceCategory
    from app.models.service import Service
    from app.models.user import User


class ExchangeRequestStatus(str, enum.Enum):
    OPEN = "open"        # actively looking for a match
    MATCHED = "matched"  # a proposal on this request was accepted
    CLOSED = "closed"    # withdrawn by its owner without matching


class ExchangeProposalStatus(str, enum.Enum):
    PENDING = "pending"
    ACCEPTED = "accepted"
    REJECTED = "rejected"
    WITHDRAWN = "withdrawn"  # the proposer cancelled it before a response


class ExchangeRequest(TimestampMixin, Base):
    """
    "I'm offering [offered_service] and want something in [wanted_category]
    in return." The unit the direct-matching algorithm operates on.
    """
    __tablename__ = "exchange_requests"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    offered_service_id: Mapped[int] = mapped_column(
        ForeignKey("services.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # Denormalized from offered_service.category_id at creation — see
    # module docstring for why. Kept in sync only at creation time since a
    # service's category essentially never changes after listing; if it
    # ever did, the request would simply need to be recreated.
    offered_category_id: Mapped[int] = mapped_column(
        ForeignKey("service_categories.id", ondelete="CASCADE"), nullable=False, index=True
    )
    wanted_category_id: Mapped[int] = mapped_column(
        ForeignKey("service_categories.id", ondelete="CASCADE"), nullable=False, index=True
    )
    wanted_custom_category_label: Mapped["str | None"] = mapped_column(String(100), nullable=True)
    status: Mapped[ExchangeRequestStatus] = mapped_column(
        SAEnum(
            ExchangeRequestStatus,
            name="exchange_request_status",
            native_enum=False,
            length=20,
            values_callable=lambda enum_cls: [m.value for m in enum_cls],
        ),
        default=ExchangeRequestStatus.OPEN,
        nullable=False,
        index=True,
    )

    # --- Relationships ---
    user: Mapped["User"] = relationship(back_populates="exchange_requests", foreign_keys=[user_id])
    offered_service: Mapped["Service"] = relationship(foreign_keys=[offered_service_id])
    offered_category: Mapped["ServiceCategory"] = relationship(foreign_keys=[offered_category_id])
    wanted_category: Mapped["ServiceCategory"] = relationship(foreign_keys=[wanted_category_id])
    proposals: Mapped[List["ExchangeProposal"]] = relationship(
        back_populates="request", cascade="all, delete-orphan", foreign_keys="ExchangeProposal.request_id"
    )

    def __repr__(self) -> str:
        return (
            f"<ExchangeRequest id={self.id} user_id={self.user_id} "
            f"offered_category_id={self.offered_category_id} "
            f"wanted_category_id={self.wanted_category_id} status={self.status.value}>"
        )


class ExchangeProposal(TimestampMixin, Base):
    """
    A concrete offer sent by `proposer` in response to someone else's
    ExchangeRequest: "I'll give you [proposed_service] for the
    [request.offered_service] you're offering." The request's owner
    (request.user) is the only one who can accept/reject.
    """
    __tablename__ = "exchange_proposals"

    id: Mapped[int] = mapped_column(primary_key=True)
    request_id: Mapped[int] = mapped_column(
        ForeignKey("exchange_requests.id", ondelete="CASCADE"), nullable=False, index=True
    )
    proposer_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    proposed_service_id: Mapped[int] = mapped_column(
        ForeignKey("services.id", ondelete="CASCADE"), nullable=False, index=True
    )
    message: Mapped[Optional[str]] = mapped_column(String(1000), nullable=True)

    status: Mapped[ExchangeProposalStatus] = mapped_column(
        SAEnum(
            ExchangeProposalStatus,
            name="exchange_proposal_status",
            native_enum=False,
            length=20,
            values_callable=lambda enum_cls: [m.value for m in enum_cls],
        ),
        default=ExchangeProposalStatus.PENDING,
        nullable=False,
        index=True,
    )

    # --- Relationships ---
    request: Mapped["ExchangeRequest"] = relationship(
        back_populates="proposals", foreign_keys=[request_id]
    )
    proposer: Mapped["User"] = relationship(
        back_populates="exchange_proposals_sent", foreign_keys=[proposer_id]
    )
    proposed_service: Mapped["Service"] = relationship(foreign_keys=[proposed_service_id])

    def __repr__(self) -> str:
        return (
            f"<ExchangeProposal id={self.id} request_id={self.request_id} "
            f"proposer_id={self.proposer_id} status={self.status.value}>"
        )
