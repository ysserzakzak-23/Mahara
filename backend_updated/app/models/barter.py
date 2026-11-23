"""
Barter-related models.

Three models work together to represent the full matching feature:

  BarterPreference  — INPUT. "I offer X, I need Y." (Phase 3)
  BarterMatch       — OUTPUT. A single detected match/cycle as a whole
                       (e.g. "this 3-way cycle was found at time T").
  BarterParticipant — OUTPUT. One row per user IN that match, recording
                       which of their preferences placed them there.

Per the product decision in Phase 9: matches are pure notifications of
opportunity, not a reservation/claim system. A user can appear in many
BarterMatch rows simultaneously (no exclusivity lock), and a BarterMatch
has no accept/reject workflow — its only mutable state is whether each
participant has VIEWED it (so the notification bell can show "new" vs
"seen"), tracked per-participant since different users see it at
different times.
"""
import enum
from typing import TYPE_CHECKING, List, Optional

from sqlalchemy import Boolean, Enum as SAEnum, ForeignKey, Integer, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.category import ServiceCategory
    from app.models.user import User


class BarterPreference(TimestampMixin, Base):
    """
    Declares that a user offers services in `offered_category` and is
    looking to receive services in `needed_category` in exchange.

    Example row: user_id=A, offered_category=Electrical Work,
                 needed_category=Phone Repair, is_active=True

    Modeled as a directed graph edge (offered_category -> needed_category,
    labeled with user_id) for the matching algorithms in
    app/algorithms/barter_matching.py: a direct match is a 2-cycle in this
    graph, a cyclic match is any longer cycle.
    """
    __tablename__ = "barter_preferences"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "offered_category_id", "needed_category_id",
            name="uq_barter_preference_user_offer_need",
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    offered_category_id: Mapped[int] = mapped_column(
        ForeignKey("service_categories.id", ondelete="CASCADE"), nullable=False, index=True
    )
    needed_category_id: Mapped[int] = mapped_column(
        ForeignKey("service_categories.id", ondelete="CASCADE"), nullable=False, index=True
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, nullable=False,
        doc="Lets a user pause a barter preference without deleting their match history",
    )

    # --- Relationships ---
    user: Mapped["User"] = relationship(back_populates="barter_preferences", foreign_keys=[user_id])
    offered_category: Mapped["ServiceCategory"] = relationship(
        back_populates="barter_preferences", foreign_keys=[offered_category_id]
    )
    needed_category: Mapped["ServiceCategory"] = relationship(foreign_keys=[needed_category_id])
    participations: Mapped[List["BarterParticipant"]] = relationship(back_populates="preference")

    def __repr__(self) -> str:
        return (
            f"<BarterPreference user_id={self.user_id} "
            f"offers={self.offered_category_id} needs={self.needed_category_id}>"
        )


class BarterMatchType(str, enum.Enum):
    DIRECT = "direct"   # a 2-party pair: A offers X/needs Y, B offers Y/needs X
    CYCLIC = "cyclic"   # a 3+ party cycle


class BarterMatch(TimestampMixin, Base):
    """
    A single detected match — either a direct pair or a cycle of 3+ users.

    This row represents the match AS A WHOLE. The individual users in it,
    and which of their preferences placed them there, are recorded as
    separate BarterParticipant rows (one per user per match) — see below.
    `cycle_length` is redundant with COUNT(participants) but is stored
    directly for cheap filtering/display without a join or aggregate query.
    """
    __tablename__ = "barter_matches"

    id: Mapped[int] = mapped_column(primary_key=True)
    match_type: Mapped[BarterMatchType] = mapped_column(
        SAEnum(
            BarterMatchType,
            name="barter_match_type",
            native_enum=False,
            length=10,
            values_callable=lambda enum_cls: [member.value for member in enum_cls],
        ),
        nullable=False,
        index=True,
    )
    cycle_length: Mapped[int] = mapped_column(Integer, nullable=False)

    # --- Relationships ---
    participants: Mapped[List["BarterParticipant"]] = relationship(
        back_populates="match", cascade="all, delete-orphan", order_by="BarterParticipant.sequence_order"
    )

    def __repr__(self) -> str:
        return f"<BarterMatch id={self.id} type={self.match_type.value} length={self.cycle_length}>"


class BarterParticipant(TimestampMixin, Base):
    """
    One row per user participating in a specific BarterMatch.

    `sequence_order` records this user's position in the cycle (0, 1, 2, ...)
    so the match can be displayed/explained in a sensible rotation order
    — e.g. "you offer to participant[i+1], and receive from participant[i-1]"
    — rather than as an unordered set of users.

    `preference_id` links back to the SPECIFIC BarterPreference that
    placed this user in this match, so the notification/detail view can
    say "your Electrical Work-for-Phone-Repair offer matched with..."
    rather than just "you matched with someone."
    """
    __tablename__ = "barter_participants"
    __table_args__ = (
        UniqueConstraint("match_id", "user_id", name="uq_barter_participant_match_user"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    match_id: Mapped[int] = mapped_column(
        ForeignKey("barter_matches.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    preference_id: Mapped[int] = mapped_column(
        ForeignKey("barter_preferences.id", ondelete="CASCADE"), nullable=False
    )
    sequence_order: Mapped[int] = mapped_column(Integer, nullable=False)
    is_viewed: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # --- Relationships ---
    match: Mapped["BarterMatch"] = relationship(back_populates="participants", foreign_keys=[match_id])
    user: Mapped["User"] = relationship(back_populates="barter_participations", foreign_keys=[user_id])
    preference: Mapped["BarterPreference"] = relationship(
        back_populates="participations", foreign_keys=[preference_id]
    )

    def __repr__(self) -> str:
        return f"<BarterParticipant match_id={self.match_id} user_id={self.user_id} order={self.sequence_order}>"
